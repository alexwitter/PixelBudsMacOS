import SwiftUI
import MaestroIOBluetooth

struct BudsPopoverView: View {
    @ObservedObject var model: BudsViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()

            if let snap = model.snapshot {
                let live = model.showsLiveData
                if !live {
                    lastSeenNotice(since: snap.updatedAt)
                } else if snap.anyStale {
                    caseClosedNotice(since: snap.staleSince)
                }
                batteryRows(snap, live: live)
                if live && snap.bothInCase {
                    inCaseHint
                }
                Divider()
                ancControl(snap)
                    .disabled(!live)
            } else if model.connectionState == .notConnected {
                Label(String(localized: "Connect your Pixel Buds to this Mac to see their battery.",
                             comment: "Shown before the first reading when the buds aren't connected"),
                      systemImage: "antenna.radiowaves.left.and.right.slash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if case .error(let message) = model.connectionState {
                errorView(message)
            } else {
                connectingPlaceholder
            }

            if let writeError = model.lastWriteError {
                writeErrorBanner(writeError)
            }

            Spacer(minLength: 0)
            footer
        }
        .padding(16)
        .frame(width: 280)
        .onAppear { model.acquireConnection() }
        .onDisappear { model.releaseConnection() }
    }

    /// Shown whenever there's no live session: the rows below are whatever
    /// the buds last told us, so say how old they are.
    private func lastSeenNotice(since: Date) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Not connected to this Mac", comment: "Notice when there is no live connection to the buds")
                    .font(.caption)
                Text("Last seen \(since, format: .relative(presentation: .named)), at \(since, format: .dateTime.hour().minute())",
                     comment: "When the shown battery levels were last read")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5))
        )
    }

    /// Shown while the case lid is closed: docked buds and the case stop
    /// reporting, so the dimmed rows below are the last levels we heard.
    private func caseClosedNotice(since: Date?) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Case closed — charge state unknown", comment: "Notice when the case lid is closed")
                    .font(.caption)
                if let since {
                    Text("Dimmed levels are from \(since, format: .dateTime.hour().minute())",
                         comment: "Time the last known battery levels were read")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.quaternary.opacity(0.5))
        )
    }

    /// Small inline banner for failed setting writes (e.g. ANC change rejected
    /// because the buds aren't in ears). The connection itself is still fine.
    private func writeErrorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .imageScale(.small)
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button {
                model.clearWriteError()
            } label: {
                Image(systemName: "xmark")
                    .imageScale(.small)
            }
            .buttonStyle(.borderless)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(.orange.opacity(0.1))
        )
    }

    private var header: some View {
        HStack {
            Text(model.snapshot?.deviceName ?? "Pixel Buds")
                .font(.headline)
            Spacer()
            statusIndicator
        }
    }

    private var statusIndicator: some View {
        Group {
            // During a short reconnect we keep showing "Connected" (see
            // BudsViewModel.showsLiveData) rather than flashing a spinner.
            switch model.showsLiveData ? .connected : model.connectionState {
            case .idle:
                Text("Idle", comment: "Connection state label in popover header").foregroundStyle(.secondary)
            case .connecting:
                HStack(spacing: 4) {
                    ProgressView().controlSize(.small)
                    Text("Connecting…", comment: "Connection state label").foregroundStyle(.secondary)
                }
            case .connected:
                HStack(spacing: 4) {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("Connected", comment: "Connection state label").foregroundStyle(.secondary)
                    if let codec = model.snapshot?.activeCodec {
                        Text("· \(codec)")
                            .foregroundStyle(.tertiary)
                    }
                }
            case .notConnected:
                HStack(spacing: 4) {
                    Circle().fill(.secondary).frame(width: 6, height: 6)
                    Text("Not connected", comment: "Connection state label").foregroundStyle(.secondary)
                }
            case .error:
                HStack(spacing: 4) {
                    Circle().fill(.red).frame(width: 6, height: 6)
                    Text("Error", comment: "Connection error label").foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }

    private var connectingPlaceholder: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(0..<3, id: \.self) { _ in
                HStack {
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 60, height: 14)
                    Spacer()
                    RoundedRectangle(cornerRadius: 4).fill(.quaternary).frame(width: 40, height: 14)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func errorView(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Couldn't connect", systemImage: "exclamationmark.triangle")
                .font(.subheadline)
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                model.forceReconnect()
            } label: {
                Label(String(localized: "Reconnect", comment: "Reconnect button"),
                      systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        }
    }

    private func batteryRows(_ snap: BudsViewModel.BudsSnapshot, live: Bool) -> some View {
        VStack(spacing: 8) {
            BatteryRow(
                label: String(localized: "Left", comment: "Earbud side label"),
                percent: Int(snap.leftBattery),
                charging: snap.leftCharging,
                placement: snap.leftInCase ? String(localized: "in case", comment: "Earbud placement label") : nil,
                stale: snap.leftStale || !live
            )
            BatteryRow(
                label: String(localized: "Right", comment: "Earbud side label"),
                percent: Int(snap.rightBattery),
                charging: snap.rightCharging,
                placement: snap.rightInCase ? String(localized: "in case", comment: "Earbud placement label") : nil,
                stale: snap.rightStale || !live
            )
            if snap.caseChargingKnown {
                BatteryRow(
                    label: String(localized: "Case", comment: "Battery case label"),
                    percent: Int(snap.caseBattery),
                    charging: snap.caseCharging,
                    placement: nil,
                    stale: snap.caseStale || !live
                )
            }
        }
    }

    private func ancControl(_ snap: BudsViewModel.BudsSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Noise Control", comment: "ANC section title").font(.subheadline)
            Picker("", selection: ancBinding(snap)) {
                Text("Off", comment: "ANC mode off").tag(MaestroPw_AncState.off)
                Text("ANC", comment: "ANC mode active — noise cancellation").tag(MaestroPw_AncState.active)
                Text("Transparency", comment: "ANC mode aware/transparency").tag(MaestroPw_AncState.aware)
                if snap.supportsAdaptiveAnc {
                    Text("Adaptive", comment: "ANC mode adaptive").tag(MaestroPw_AncState.adaptive)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            // Firmware refuses ANC writes while both buds are docked, so we
            // disable the picker and let the in-case banner explain why.
            .disabled(snap.bothInCase)
        }
    }

    /// Informational banner shown when both buds are sitting in the case.
    /// Most settings writes will fail with status 9 in that state, so we tell
    /// the user upfront instead of letting them discover it through errors.
    private var inCaseHint: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "info.circle")
                .foregroundStyle(.secondary)
                .imageScale(.small)
            Text("Buds are in the case. Take one out and wear it to change settings.", comment: "In-case hint banner")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func ancBinding(_ snap: BudsViewModel.BudsSnapshot) -> Binding<MaestroPw_AncState> {
        Binding(
            get: { snap.anc },
            set: { model.setAnc($0) }
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let s = model.snapshot {
                Text("Updated \(s.updatedAt, format: .dateTime.hour().minute().second())")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                model.forceReconnect()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Reconnect")
            Button {
                NotificationCenter.default.post(name: .openPixelBudsSettings, object: nil)
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Settings…")
            Button(String(localized: "Quit", comment: "Quit application button")) {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
    }
}

private struct BatteryRow: View {
    let label: String
    let percent: Int
    let charging: Bool
    let placement: String?
    /// Last-known level from a closed case: dimmed, with no charging bolt
    /// because we can't see whether it's charging.
    var stale = false

    /// Fixed-width columns so every row lines up and nothing shifts when the
    /// bolt or placement text comes and goes:
    /// label · placement · bolt · percent (room for "100%") · bar (fills the rest).
    var body: some View {
        HStack(spacing: 6) {
            Text(label).frame(width: 40, alignment: .leading)
            Text(placement ?? "")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 40, alignment: .trailing)
            Image(systemName: "bolt.fill")
                .foregroundStyle(.green)
                .imageScale(.small)
                .opacity(charging && !stale ? 1 : 0)
                .frame(width: 12)
            Text("\(percent)%")
                .font(.system(.body, design: .monospaced))
                .frame(width: 40, alignment: .trailing)
            BatteryBar(percent: percent, charging: charging)
        }
        .opacity(stale ? 0.4 : 1)
    }
}

private struct BatteryBar: View {
    let percent: Int
    let charging: Bool

    private var fraction: CGFloat {
        CGFloat(max(0, min(100, percent))) / 100.0
    }

    private var color: Color {
        if percent < 20 { return .red }
        if percent < 40 { return .yellow }
        return .green
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 3)
                    .fill(.quaternary)
                RoundedRectangle(cornerRadius: 3)
                    .fill(color)
                    .frame(width: geo.size.width * fraction)
            }
        }
        .frame(height: 10)
    }
}
