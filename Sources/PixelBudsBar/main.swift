import AppKit

// PixelBudsBar is a menu-bar-only app: the whole UI is owned by AppDelegate
// (NSStatusItem + NSPopover + an NSWindow hosting SwiftUI views via
// NSHostingController). It has no SwiftUI `Scene`.
//
// It used to be a SwiftUI `App` whose body was `Settings { EmptyView() }`,
// present only to satisfy the `App` protocol. SwiftUI presents its scenes at
// launch through AppWindowsController.showInitialWindows(), so that empty
// scene surfaced as a blank "Pixel Buds Bar Settings" window next to the real
// AppDelegate-owned one. A plain AppKit entry point has no scenes to present.

let app = NSApplication.shared

// Top-level code is nonisolated but does run on the main thread, so assume the
// isolation rather than hopping. Held in a global because NSApplication only
// keeps a weak reference to its delegate.
let delegate = MainActor.assumeIsolated { AppDelegate() }

MainActor.assumeIsolated {
    app.delegate = delegate
    app.mainMenu = delegate.makeMainMenu()
}

app.run()
