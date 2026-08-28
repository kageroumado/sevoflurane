import AppKit
import Propofol
import SwiftUI

/// The popover's bottom bar: what the client is doing on the left, what to do about it on the
/// right.
///
/// Every action that isn't a universal glyph carries its name. Reload and restart used to be two
/// adjacent circular arrows that only their tooltips could tell apart; they live in the actions
/// menu now, as words. What stays iconic is the pair every menu-bar app draws the same way —
/// the gear and the close box.
struct FooterBar: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        // One `GlassEffectContainer` over the whole bar at one control size: glass sampled per
        // control picks up whatever sits behind that spot, which is what made the status chips
        // and the glyph buttons look like different materials.
        GlassEffectContainer(spacing: Theme.Space.sm) {
            HStack(spacing: Theme.Space.sm) {
                StatusChip(host: host, supervisor: supervisor)
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
                    .help("Quit Sevoflurane and shut down the Steam client")
                    .accessibilityLabel("Quit")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
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
                    Divider()
                    Button("Open Event Log", systemImage: "doc.text") {
                        NSWorkspace.shared.open(EventLog.fileURL)
                    }
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }
            .help("Reload, restart, and the event log")
            .accessibilityLabel("More actions")
    }

    /// A glyph for the bottom-bar utility controls, pinned to a fixed square so every glass
    /// capsule comes out the same size regardless of glyph proportions.
    private func utilityIcon(_ name: String) -> some View {
        Image(systemName: name)
            .frame(width: 16, height: 16)
    }
}

// MARK: - Status chip

/// The footer's status atom: a health dot and one word at rest; on hover it flips into the
/// auto-restart switch, so the setting costs no space.
private struct StatusChip: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @State private var isHovered = false

    private var status: (word: String, color: Color) {
        switch supervisor.health {
        case .starting: ("Starting", .gray)
        case .healthy: ("Healthy", .green)
        case .waitingForSignIn: ("Signed out", .gray)
        case .degraded: ("Degraded", .orange)
        case .restarting: ("Restarting", .accentColor)
        case .launching: ("Starting", .accentColor)
        case .gaveUp: ("Stopped", .red)
        case .paused: ("Paused", .gray)
        }
    }

    private var tooltip: String {
        var lines = ["\(supervisor.statusText) · \(host.status)"]
        if let event = EventLog.shared.latest {
            let time = event.date.formatted(date: .omitted, time: .shortened)
            lines.append("last event \(time) — \(event.message)")
        }
        lines.append("Click to pause or resume auto-restart.")
        return lines.joined(separator: "\n")
    }

    var body: some View {
        Button { supervisor.togglePaused() } label: {
            HStack(spacing: Theme.Space.xs) {
                if isHovered {
                    SwitchPip(isOn: supervisor.health != .paused)
                    Text("Auto-restart")
                } else {
                    StatusDot(color: status.color, diameter: 7)
                    Text(status.word)
                }
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .help(tooltip)
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
            .help("Version \(available) is available — click to install it now")
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
            }
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .help("Install updates automatically, once no game is running")
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
