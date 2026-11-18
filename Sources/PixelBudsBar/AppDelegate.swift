import AppKit
import Combine
import IOBluetooth
import KeyboardShortcuts
import MaestroIOBluetooth
import OSLog
import SwiftUI

private let log = Logger(subsystem: "com.kshmlg.PixelBudsBar", category: "bt-watch")

extension Notification.Name {
    /// Posted by the popover (or anywhere else in the UI) to ask the
    /// AppDelegate to open the settings window. Using a notification keeps
    /// SwiftUI views decoupled from the concrete delegate type.
    static let openPixelBudsSettings = Notification.Name("openPixelBudsSettings")
}

/// Owns the menu-bar UI: NSStatusItem with our custom icon + battery %,
/// plus an NSPopover that hosts BudsPopoverView. The model state is observed
/// via Combine so the status item label tracks @Published changes.
///
/// We use NSStatusItem instead of SwiftUI's MenuBarExtra because MenuBarExtra
/// doesn't expose programmatic control over its popover — we need that to
/// auto-open on first launch so the user discovers the icon.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let model = BudsViewModel()
    let loginItem = LoginItemManager()
    private let lowBatteryNotifier = LowBatteryNotifier()

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var cancellables: Set<AnyCancellable> = []

    /// Retains the IOBluetooth baseband-connect subscription. When the buds
    /// re-establish their ACL link (e.g. multipoint focus handed back from the
    /// phone), this fires and we rebuild the Maestro session immediately
    /// instead of waiting on the blind backoff loop in BudsViewModel.
    private var budsConnectNotification: IOBluetoothUserNotification?

    /// Settings window is created lazily on first open and reused afterwards.
    private var settingsWindow: NSWindow?
    /// True while the settings window has acquired the model's connection.
    /// Prevents double-acquire on re-open and double-release on close.
    private var settingsHoldsConnection = false

    /// Toggleable from Settings → Application. When true (the default) we
    /// pop the popover every time the app launches, so the latest battery
    /// and connection state are visible without clicking. False starts the
    /// app silent — the icon is there, but nothing pops.
    static let autoOpenOnLaunchKey = "pixelBudsBar.autoOpenOnLaunch"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        configureStatusItem()
        configurePopover()
        observeModel()

        // If the user has background monitoring enabled (default ON) acquire
        // a long-lived connection slot now so battery alerts work without
        // requiring the popover to be open.
        model.bootstrapBackgroundMonitoring()

        observeBluetoothReconnects()

        // Register the system-wide hotkey for "ring both buds". The handler
        // only fires when the user has configured a combination in Settings;
        // until then KeyboardShortcuts ignores it silently.
        KeyboardShortcuts.onKeyUp(for: .ringBuds) { [weak self] in
            guard let self else { return }
            // Only attempt the ring if the GFPS channel actually opened —
            // otherwise we'd just produce a confusing write error in the UI.
            guard self.model.snapshot?.canRingBuds == true else { return }
            self.model.ringBuds(.both)
        }

        NotificationCenter.default.addObserver(
            forName: .openPixelBudsSettings,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // `queue: .main` guarantees we're on the main queue at runtime,
            // but the closure type itself is nonisolated. Assume isolation
            // so the call into our @MainActor method type-checks without an
            // extra Task hop.
            MainActor.assumeIsolated {
                self?.openSettings()
            }
        }

        // Launch UX: pop the popover so battery / connection state are
        // immediately visible. Two subtleties make this trickier than a
        // straight `showPopover()`:
        //  * AppKit needs a beat to lay out the status item, otherwise
        //    `popover.show(relativeTo:of:)` anchors to a button whose
        //    window isn't on screen yet and nothing renders.
        //  * Accessory apps start inactive, so a .transient popover
        //    dismisses itself the same run-loop tick it opens. Calling
        //    `NSApp.activate(...)` first makes it stick until the user
        //    clicks somewhere else.
        let defaults = UserDefaults.standard
        let autoOpenAllowed = defaults.object(forKey: Self.autoOpenOnLaunchKey) as? Bool ?? true
        if autoOpenAllowed {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                guard let self else { return }
                NSApp.activate(ignoringOtherApps: true)
                self.showPopover()
            }
        }
    }

    // MARK: - Setup

    private func configureStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = statusItem.button else { return }
        button.action = #selector(handleStatusItemClick(_:))
        button.target = self
        // Left = popover, right = NSMenu. We intentionally don't set
        // `statusItem.menu` directly because that hijacks the left-click too;
        // dispatching on both events and branching on `currentEvent.type`
        // keeps left-click behavior unchanged.
        button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        refreshStatusItem()
    }

    private func configurePopover() {
        popover.behavior = .transient
        popover.animates = true
        let hosting = NSHostingController(rootView: BudsPopoverView(model: model))
        // Let the popover size itself to whatever SwiftUI's intrinsic content
        // size happens to be (depends on number of battery rows, error state, etc.)
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
    }

    private func observeModel() {
        Publishers
            .CombineLatest(model.$snapshot, model.$connectionState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _ in self?.refreshStatusItem() }
            .store(in: &cancellables)

        // Funnel each new snapshot into the low-battery notifier. Distinct
        // values only, so a noisy stream of identical snapshots doesn't
        // matter — the notifier already has hysteresis but skipping the
        // re-evaluation entirely is cheaper.
        model.$snapshot
            .compactMap { $0 }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snap in
                self?.lowBatteryNotifier.process(snapshot: snap)
            }
            .store(in: &cancellables)
    }

    /// Subscribe to system-wide Bluetooth baseband connect events. IOBluetooth
    /// delivers these on the registering thread's run loop — we register from
    /// the main run loop here, so `budsBasebandConnected` is invoked on main.
    private func observeBluetoothReconnects() {
        budsConnectNotification = IOBluetoothDevice.register(
            forConnectNotifications: self,
            selector: #selector(budsBasebandConnected(_:device:))
        )
    }

    /// Fires whenever *any* Bluetooth device establishes a baseband connection.
    /// We filter to our Pixel Buds and, when we're not already healthy, force a
    /// fresh Maestro session. A baseband (re)connect after a multipoint handoff
    /// almost always means our RFCOMM control channel went stale, so this is the
    /// moment to rebuild it — and it un-wedges the case where the backoff loop
    /// has been failing to re-acquire the channel while the phone held primary.
    @objc private func budsBasebandConnected(
        _ notification: IOBluetoothUserNotification,
        device: IOBluetoothDevice
    ) {
        let cod = UInt32(device.classOfDevice)
        let isBuds = (device.name ?? "").lowercased().contains("pixel buds")
            && (cod == 0x240404 || cod == 0x244404)
        guard isBuds else { return }
        // Only intervene when we're idle or wedged in an error. We must NOT
        // interrupt an in-progress connect (`.connecting`) — that includes the
        // very first connect at launch, which races this notification — nor a
        // healthy `.connected` session (its own stream-drop handling covers
        // blips). Forcing a reconnect mid-open would cancel the in-flight open
        // and churn for nothing.
        switch model.connectionState {
        case .connecting, .connected:
            return
        case .idle, .notConnected, .error:
            log.info("buds baseband connected while \(String(describing: self.model.connectionState)) — forcing Maestro reconnect")
            model.forceReconnect()
        }
    }

    // MARK: - Status item rendering

    private func refreshStatusItem() {
        guard let button = statusItem?.button else { return }
        if case .error = model.connectionState {
            button.image = NSImage(systemSymbolName: "exclamationmark.circle",
                                   accessibilityDescription: "Pixel Buds — error")
            button.title = ""
        } else {
            // ANC badge: only show a colored dot when ANC is actively doing
            // something (Off/Unknown get no dot).
            // Until we have a live session, the snapshot is from the last one:
            // draw empty outlines rather than old levels that look current.
            let live = model.connectionState == .connected
            let s = model.snapshot
            let ancBadge = live ? Self.ancBadgeColor(for: s?.anc) : nil
            let left = s.map { Gauge(level: $0.leftBattery, charging: $0.leftCharging, stale: $0.leftStale || !live) }
            let right = s.map { Gauge(level: $0.rightBattery, charging: $0.rightCharging, stale: $0.rightStale || !live) }
            button.image = Self.budsIcon(left: left, right: right, ancBadge: ancBadge)
            button.title = ""
            button.setAccessibilityLabel(Self.accessibilityLabel(left: left, right: right))
        }
    }

    private static func accessibilityLabel(left: Gauge?, right: Gauge?) -> String {
        func describe(_ g: Gauge?) -> String {
            guard let g, g.isKnown else { return String(localized: "unknown") }
            return g.charging ? "\(g.level)%, charging" : "\(g.level)%"
        }
        return String(localized: "Pixel Buds: left \(describe(left)), right \(describe(right))")
    }

    private static func ancBadgeColor(for state: MaestroPw_AncState?) -> NSColor? {
        switch state {
        case .active:   return .systemBlue
        case .aware:    return .systemGreen
        case .adaptive: return .systemPurple
        default:        return nil
        }
    }


    // MARK: - Popover lifecycle

    @objc private func handleStatusItemClick(_ sender: Any?) {
        // `currentEvent` is set by AppKit to the event that fired the action,
        // so we can tell apart left vs. right click without subclassing the
        // status bar button.
        if NSApp.currentEvent?.type == .rightMouseUp {
            showContextMenu()
            return
        }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Bring the popover's window to front so it doesn't render behind other apps.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// Builds the app's main menu bar. The SwiftUI `App` wrapper used to
    /// supply this implicitly; with a plain AppKit entry point we own it.
    /// Without it ⌘Q and ⌘W stop working while the settings window is open —
    /// an accessory app shows no menu bar until `openSettings()` flips the
    /// activation policy to `.regular`.
    func makeMainMenu() -> NSMenu {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? ProcessInfo.processInfo.processName

        let mainMenu = NSMenu()

        // App menu. AppKit names it from the first item's submenu, so the
        // submenu carries the title rather than the top-level item.
        let appMenu = NSMenu(title: appName)

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        appMenu.addItem(settingsItem)

        appMenu.addItem(.separator())

        appMenu.addItem(NSMenuItem(
            title: "Hide \(appName)",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        ))

        appMenu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit \(appName)",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        appMenu.addItem(quitItem)

        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Window menu — this is what gives the settings window ⌘W. The items
        // are nil-targeted so AppKit routes them to the key window.
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(NSMenuItem(
            title: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        ))
        windowMenu.addItem(NSMenuItem(
            title: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m"
        ))

        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        return mainMenu
    }

    /// Builds and displays the right-click NSMenu next to the status item.
    /// We construct it fresh each time so item enablement (Ring) reflects the
    /// current snapshot without needing a validator selector.
    private func showContextMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let ringItem = NSMenuItem(
            title: "Ring both buds",
            action: #selector(menuRingBuds),
            keyEquivalent: ""
        )
        ringItem.target = self
        ringItem.isEnabled = model.snapshot?.canRingBuds == true
        menu.addItem(ringItem)

        let reconnectItem = NSMenuItem(
            title: "Reconnect",
            action: #selector(menuReconnect),
            keyEquivalent: ""
        )
        reconnectItem.target = self
        menu.addItem(reconnectItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(
            title: "Settings…",
            action: #selector(menuOpenSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Pixel Buds Bar",
            action: #selector(menuQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        // Attach + pop + detach: setting `statusItem.menu = nil` after the
        // user dismisses the menu means the next left-click still opens the
        // popover (otherwise AppKit would re-show this menu).
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func menuRingBuds() {
        guard model.snapshot?.canRingBuds == true else { return }
        model.ringBuds(.both)
    }

    @objc private func menuReconnect() {
        model.forceReconnect()
    }

    @objc private func menuOpenSettings() {
        openSettings()
    }

    @objc private func menuQuit() {
        NSApp.terminate(nil)
    }

    // MARK: - Settings window

    /// Open (or refocus) the settings window. Holds a connection ticket while
    /// the window is visible so the popover closing afterwards doesn't churn
    /// the RFCOMM channel.
    func openSettings() {
        if settingsWindow == nil {
            let controller = NSHostingController(
                rootView: SettingsView(model: model, loginItem: loginItem)
            )
            controller.sizingOptions = .preferredContentSize

            // Build the window explicitly so size + style mask are guaranteed,
            // rather than relying on NSWindow(contentViewController:) defaults.
            // The sidebar layout asks for ~720×780 via its idealWidth/idealHeight;
            // matching the initial rect avoids a visible reflow on first open.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 720, height: 780),
                styleMask: [.titled, .closable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.contentViewController = controller
            window.title = "Pixel Buds Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            settingsWindow = window
        }
        // Acquire BEFORE popover closes so we don't drop count to 0 in the
        // middle of switching surfaces.
        if !settingsHoldsConnection {
            model.acquireConnection()
            settingsHoldsConnection = true
        }
        // Accessory apps don't bring windows to front via .activate alone;
        // temporarily switch to .regular so the OS treats the settings window
        // as a real app window. We flip back to .accessory on close.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        // Bounce to the main actor since the protocol method is nonisolated.
        Task { @MainActor in
            guard let window = notification.object as? NSWindow,
                  window == self.settingsWindow else { return }
            if self.settingsHoldsConnection {
                self.model.releaseConnection()
                self.settingsHoldsConnection = false
            }
            // Revert to menu-bar-only mode now that no window is visible.
            NSApp.setActivationPolicy(.accessory)
        }
    }

    // MARK: - Menu-bar icon

    /// One bud's battery as drawn in the menu bar.
    struct Gauge {
        var level: Int32
        var charging: Bool
        /// Last-known level from a closed case (see BudsSnapshot.leftStale).
        var stale: Bool
        /// A bud asleep in a closed case reports 0; draw that as unknown, not flat.
        var isKnown: Bool { level > 0 && !stale }
    }

    /// Same threshold as LowBatteryNotifier.
    private static let lowBatteryThreshold: Int32 = 15
    private static let barWidth: CGFloat = 5.5
    private static let barGap: CGFloat = 2.5
    /// The 14pt headphones symbol's image is 17pt square, but its visible
    /// shape runs from about 2pt below the top to 1.125pt above the bottom
    /// (measured from a render). The batteries span exactly that, so they
    /// match the headphones' height.
    private static let glyphInkTopInset: CGFloat = 2
    private static let glyphInkBottomInset: CGFloat = 1.125
    private static let iconHeight: CGFloat = 18

    private static let headphones: NSImage? = NSImage(
        systemSymbolName: "headphones",
        accessibilityDescription: nil
    )?.withSymbolConfiguration(.init(pointSize: 14, weight: .regular))

    /// Headphones glyph flanked by a small vertical battery for each bud,
    /// left bud on the left, styled after the iPad status bar:
    /// - fill height is the level; label colour, red at or below 15%, green
    ///   while charging
    /// - an empty, faint outline when the level is unknown (asleep in a closed
    ///   case, or not connected yet)
    /// - `ancBadge`: coloured dot for the current ANC mode, in the empty space
    ///   between the ear cups.
    private static func budsIcon(left: Gauge?, right: Gauge?, ancBadge: NSColor?) -> NSImage? {
        guard let glyph = headphones else { return nil }
        let glyphSize = glyph.size
        let size = NSSize(width: barWidth * 2 + barGap * 2 + glyphSize.width, height: iconHeight)

        let composite = NSImage(size: size, flipped: false) { rect in
            let glyphRect = NSRect(x: barWidth + barGap,
                                   y: (rect.height - glyphSize.height) / 2,
                                   width: glyphSize.width, height: glyphSize.height)

            let barY = glyphRect.minY + glyphInkBottomInset
            let barSize = NSSize(width: barWidth,
                                 height: glyphRect.height - glyphInkTopInset - glyphInkBottomInset)
            drawBattery(left, in: NSRect(origin: NSPoint(x: 0, y: barY), size: barSize))
            drawBattery(right, in: NSRect(origin: NSPoint(x: rect.maxX - barWidth, y: barY), size: barSize))

            // Tint the glyph: draw it, then paint label colour over its alpha.
            NSGraphicsContext.saveGraphicsState()
            glyph.draw(in: glyphRect)
            NSColor.labelColor.setFill()
            glyphRect.fill(using: .sourceAtop)
            NSGraphicsContext.restoreGraphicsState()

            if let badge = ancBadge {
                let dotSize: CGFloat = 4.5
                badge.setFill()
                NSBezierPath(ovalIn: NSRect(x: glyphRect.midX - dotSize / 2, y: glyphRect.minY + 1,
                                            width: dotSize, height: dotSize)).fill()
            }
            return true
        }
        composite.size = size
        // Re-render on every draw so labelColor tracks appearance changes
        // (light/dark mode, accessibility tint) without us having to observe.
        composite.cacheMode = .never
        composite.isTemplate = false
        return composite
    }

    /// A tiny upright battery: outlined body with a nub on top, filled from
    /// the bottom by `gauge.level`.
    private static func drawBattery(_ gauge: Gauge?, in rect: NSRect) {
        let known = gauge?.isKnown ?? false
        let outline = NSColor.labelColor.withAlphaComponent(known ? 0.6 : 0.3)

        let nubHeight: CGFloat = 1.5
        let nub = NSRect(x: rect.midX - 1, y: rect.maxY - nubHeight, width: 2, height: nubHeight)
        outline.setFill()
        NSBezierPath(roundedRect: nub, xRadius: 0.5, yRadius: 0.5).fill()

        let body = NSRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height - nubHeight)
            .insetBy(dx: 0.5, dy: 0.5)
        let frame = NSBezierPath(roundedRect: body, xRadius: 1.2, yRadius: 1.2)
        frame.lineWidth = 1
        outline.setStroke()
        frame.stroke()

        guard let gauge, known else { return }
        let inner = body.insetBy(dx: 1.25, dy: 1.25)
        let fraction = CGFloat(min(100, max(0, gauge.level))) / 100
        // At least 2pt so a nearly flat bud still shows a visible red sliver.
        let fill = NSRect(x: inner.minX, y: inner.minY,
                          width: inner.width, height: max(2, inner.height * fraction))
        let color: NSColor = gauge.charging ? .systemGreen
            : gauge.level <= lowBatteryThreshold ? .systemRed
            : .labelColor
        color.setFill()
        NSBezierPath(roundedRect: fill, xRadius: 0.5, yRadius: 0.5).fill()
    }
}
