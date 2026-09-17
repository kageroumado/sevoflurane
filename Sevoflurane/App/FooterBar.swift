import AppKit
import Propofol
import SwiftUI

/// The popover's bottom bar: what the client is doing on the left, what to do about it on the
/// right.
///
/// Every action that isn't a universal glyph carries its name: reload and restart live in the
/// actions menu, as words. What stays iconic is the pair every menu-bar app draws the same way —
/// the gear and the close box.
struct FooterBar: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    /// The label box every capsule in the bar is built around. A glass capsule sizes to its label,
    /// so the label is where sameness has to be imposed: the glyph buttons draw their symbol in
    /// this box and the two text chips are pinned to its height, which is what keeps the status
    /// chip from sitting a few points shorter than the gear beside it.
    static let labelBox: CGFloat = 16

    var body: some View {
        // One `GlassEffectContainer` over the whole bar at one control size: glass sampled per
        // control picks up whatever sits behind that spot, which is what made the status chips
        // and the glyph buttons look like different materials.
        // Tight spacing and small controls, because the width is the binding constraint: five
        // capsules share a 320-point popover and two of them grow on hover into a switch and its
        // name. Loosening either one costs a label its last characters.
        GlassEffectContainer(spacing: Theme.Space.xs) {
            HStack(spacing: Theme.Space.xs) {
                StatusChip(host: host, supervisor: supervisor)
                if case .gaveUp = supervisor.health {
                    Button("Recovery…") {
                        NSApp.sendAction(#selector(AppDelegate.showRecovery(_:)), to: nil, from: nil)
                    }
                    .font(.system(size: 11, weight: .medium))
                    .fixedSize()
                    .help("Open Settings › Recovery: restart, repair, or report")
                }
                DebugChip()
                UpdateChip()
                Spacer(minLength: 0)
                actionsMenu
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
                } label: { utilityIcon("gearshape") }
                    .help("Settings")
                    .accessibilityLabel("Settings")
                Button { NSApplication.shared.terminate(nil) } label: { utilityIcon("xmark") }
                    .keyboardShortcut("q")
                    .help("Quit Sevoflurane and close Steam")
                    .accessibilityLabel("Quit")
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.small)
        }
    }

    /// `Menu` draws its own background and sizes to its label, so however it is styled it comes
    /// out narrower and darker than the `.glass` buttons beside it. So it draws nothing: the
    /// visible control is a real `.glass` button — a sibling of the other two, identical by
    /// construction — and the menu is a transparent layer over it that takes the click.
    private var actionsMenu: some View {
        Button {} label: { utilityIcon("ellipsis") }
            .allowsHitTesting(false)
            .overlay {
                Menu {
                    Button("Reload Steam UI", systemImage: "arrow.clockwise") { host.reload() }
                    Button("Restart Steam Client", systemImage: "arrow.triangle.2.circlepath") {
                        supervisor.restartNow()
                    }
                    // Steam restarts leave the fake Windows booted; this is
                    // the full machine reboot for when Windows itself is
                    // suspect.
                    Button("Restart Windows", systemImage: "power.circle") {
                        supervisor.restartWindowsNow()
                    }
                    Divider()
                    // The force rungs, for when a graceful restart is the
                    // thing that is stuck: kill now, no waiting, then come
                    // back clean.
                    Button("Force-Quit Steam", systemImage: "xmark.octagon", role: .destructive) {
                        supervisor.forceQuit(.steam)
                    }
                    Button(
                        "Force-Quit Everything", systemImage: "exclamationmark.octagon",
                        role: .destructive,
                    ) {
                        supervisor.forceQuit(.everything)
                    }
                    Divider()
                    Button("Open Event Log", systemImage: "doc.text") {
                        NSWorkspace.shared.open(EventLog.fileURL)
                    }
                    debugModeItem
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .help("Reload, restart, and the event log")
            .accessibilityLabel("More actions")
    }

    /// The playtest switch, and — while a client is already up under the old environment — the
    /// restart that carries it to the client and its games. The app half is on the moment the
    /// toggle is pressed; the engine half is read by a program at its start, so a running Steam
    /// keeps the channels it booted with.
    @ViewBuilder private var debugModeItem: some View {
        let debug = DebugModeSwitch.shared
        Toggle(isOn: Binding(get: { debug.isOn }, set: { debug.set($0) })) {
            Label("Debug Mode", systemImage: "ladybug")
        }
        .help("Logs library loads, renderer errors, and the engine's frame trail. "
            + "Stops when the app quits.")
        if debug.isOn, isClientUp {
            Button("Restart Steam to Apply Debug Mode") {
                supervisor.restartNow(reason: "debug mode")
            }
        }
    }

    /// Whether a client is running under the environment debug mode has just changed.
    private var isClientUp: Bool {
        switch supervisor.health {
        case .healthy, .degraded, .waitingForSignIn: true
        case .starting, .launching, .restarting, .gaveUp, .paused: false
        }
    }

    /// A glyph for the bottom-bar utility controls, pinned to the shared label box so every glass
    /// capsule comes out the same size regardless of glyph proportions.
    private func utilityIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: Self.labelBox, height: Self.labelBox)
    }
}

// MARK: - Status chip

/// The footer's status atom: a health dot and the state of the Steam client at rest; on hover it
/// flips into the auto-restart switch, so the setting costs no space.
private struct StatusChip: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @State private var isHovered = false

    /// Every label that reports the client's run state names Steam, because the dot alone says
    /// only "good" and nothing in the footer says what it is good about. The three that skip the
    /// name report something else: the Steam account, this app's own switch, and the restart it is
    /// in the middle of.
    private var status: (word: String, color: Color) {
        switch supervisor.health {
        case .starting: ("Steam starting", .gray)
        case .healthy: ("Steam running", .green)
        case .waitingForSignIn: ("Signed out", .gray)
        case .degraded: ("Steam wedged", .orange)
        case .restarting: ("Restarting", .accentColor)
        case .launching: ("Steam starting", .accentColor)
        case .gaveUp: ("Steam stopped", .red)
        case .paused: ("Paused", .gray)
        }
    }

    private var tooltip: String {
        var lines = ["\(supervisor.statusText) · \(host.status)"]
        if let event = EventLog.shared.latest {
            let time = event.date.formatted(date: .omitted, time: .shortened)
            lines.append("last event \(time) · \(event.message)")
        }
        lines.append("Hover for the auto-restart switch.")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            if isHovered {
                // Only the switch takes the press. A readout that reads as a status light and
                // acts as a toggle is a trap: the playtest's two unexplained pauses were both
                // clicks on what looked like the light.
                Button { supervisor.togglePaused() } label: {
                    SwitchPip(isOn: supervisor.health != .paused)
                }
                .buttonStyle(.plain)
                .help("Turn auto-restart on or off")
                Text("Auto-restart")
            } else {
                StatusDot(color: status.color, diameter: 7)
                Text(status.word)
            }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        // A truncated switch label is unreadable — "Auto-…" names nothing — so the chip takes
        // the width its label asks for and the bar is sized to afford it.
        .fixedSize()
        .frame(height: FooterBar.labelBox)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(tooltip)
    }
}

// MARK: - Debug chip

/// Present only while debug mode is on, because that is the whole of what it says: the logs are
/// growing and something turned them on. Its tooltip carries the sizes, so "how much" is a hover
/// rather than a trip to the Finder.
private struct DebugChip: View {
    var body: some View {
        let debug = DebugModeSwitch.shared
        if debug.isOn {
            Label("Debug", systemImage: "ladybug.fill")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .frame(height: FooterBar.labelBox)
                .help(debug.summary)
        }
    }
}

// MARK: - Update chip

/// The version chip is the whole update UI: it announces an update (click installs), confirms one
/// just landed (click acknowledges), and at rest flips into the Auto-Update switch on hover so the
/// setting costs no footer space.
private struct UpdateChip: View {
    @AppStorage("autoUpdate") private var autoUpdate = true
    @State private var isHovered = false

    var body: some View {
        let updates = SilentUpdates.shared
        switch updates.manualPhase {
        case .working:
            HStack(spacing: Theme.Space.xs) {
                ProgressView().controlSize(.small)
                Text("Updating…").font(.caption).foregroundStyle(.secondary)
            }
        case let .failed(message):
            Button {
                NSWorkspace.shared.open(updates.releasesPageURL)
                updates.dismissFailure()
            } label: {
                Label("Update failed", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help(message)
        case .idle:
            idleChip(updates)
        }
    }

    @ViewBuilder
    private func idleChip(_ updates: SilentUpdates) -> some View {
        if let justUpdated = updates.justUpdatedVersion {
            Button { updates.acknowledgeUpdate() } label: {
                Label("v\(justUpdated)", systemImage: "checkmark")
                    .font(.caption)
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help("Updated to version \(justUpdated)")
        } else if let available = updates.availableVersion ?? updates.pendingVersion {
            Button { Task { await updates.updateNow() } } label: {
                Label("v\(available)", systemImage: "arrow.down.circle.fill")
                    .font(.caption)
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.glassProminent)
            .controlSize(.small)
            .help("Click to install version \(available)")
        } else {
            Button {
                autoUpdate.toggle()
                updates.setAutoInstall(autoUpdate)
            } label: {
                Group {
                    if isHovered {
                        HStack(spacing: 5) {
                            SwitchPip(isOn: autoUpdate)
                            Text("Auto")
                        }
                    } else {
                        Text(Self.versionString)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize()
                .frame(height: FooterBar.labelBox)
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .help("Install updates automatically while no game runs")
        }
    }

    private static var versionString: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
        return "v\(version)"
    }
}

// MARK: - Switch pip

/// The miniature toggle both hover-flip chips wear in place of their resting label.
struct SwitchPip: View {
    let isOn: Bool

    var body: some View {
        Capsule()
            .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
            .frame(width: 20, height: 12)
            .overlay(alignment: isOn ? .trailing : .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: 8, height: 8)
                    .padding(2)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
    }
}
