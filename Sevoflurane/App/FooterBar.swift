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
    /// While the first-run assistant is unfinished there is no client to
    /// report on or restart, and nothing configured for Settings to change:
    /// the bar keeps the version and Quit.
    var isSettingUp = false
    /// The ✕: asks before quitting (``QuitConfirmation``), because quitting
    /// takes Steam and a running game down with it.
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    var body: some View {
        // One `GlassEffectContainer` over the whole bar: glass sampled per control picks up
        // whatever sits behind that spot, which is what made the chips and the glyph buttons look
        // like different materials. Zero blend distance, because the controls sit closer together
        // than any nonzero spacing allows before their glass pools into one shape.
        // Tight spacing, because the width is the binding constraint: five controls share a
        // 320-point popover and the version chip grows on hover into a switch and its name.
        // Loosening it costs a label its last characters.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                if !isSettingUp {
                    StatusChip(host: host, supervisor: supervisor)
                }
                if hasGivenUp, !isSettingUp {
                    Button("Recovery…") {
                        NSApp.sendAction(#selector(AppDelegate.showRecovery(_:)), to: nil, from: nil)
                    }
                    .buttonStyle(.footerChip)
                    .help("Open Settings › Recovery: restart, repair, or report")
                }
                DebugChip()
                // The resting version gives its place to Recovery…: the bar holds one of the two,
                // and while the client is down the way back up is the one that matters.
                UpdateChip(showsRestingVersion: !hasGivenUp)
                Spacer(minLength: 0)
                if !isSettingUp {
                    actionsMenu
                    settingsButton
                }
                FooterIconButton("Quit", systemImage: "xmark", action: onQuit)
                    .keyboardShortcut("q")
                    .help("Quit Sevoflurane and close Steam")
            }
        }
    }

    private var hasGivenUp: Bool {
        if case .gaveUp = supervisor.health { true } else { false }
    }

    /// The gear, wearing a dot when the release feed has an engine or a renderer version this Mac
    /// does not — which is where the update check gets said out loud, since everything under the app
    /// is fetched from Settings.
    private var settingsButton: some View {
        let summary = UpdateSummary.shared.summary
        return FooterIconButton(summary.map { "Settings — \($0)" } ?? "Settings", systemImage: "gearshape") {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
        .help(summary ?? "Settings")
        .overlay(alignment: .topTrailing) {
            if summary != nil {
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 6, height: 6)
                    .allowsHitTesting(false)
            }
        }
    }

    /// `Menu` draws its own background and sizes to its label, so however it is styled it comes
    /// out narrower and darker than the glass circles beside it. So it draws nothing: the visible
    /// control is a real `FooterIconButton` — a sibling of the other two, identical by
    /// construction — and the menu is a transparent layer over it that takes the click.
    private var actionsMenu: some View {
        FooterIconButton("More actions", systemImage: "ellipsis") {}
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
        .help(Engine.active.supportsEnvFiles
            ? "Logs library loads, renderer errors, and the engine's frame trail. "
            + "Stops when the app quits."
            : "Logs more of what Sevoflurane does. The engine's own logging needs Dormison. "
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
}

// MARK: - Status chip

/// The footer's status atom: a health dot and the state of the Steam client. Never give it a
/// control: a status light that also toggles gets pressed as a light — the playtest's two
/// unexplained pauses were exactly that. The auto-restart switch is in Settings › General.
private struct StatusChip: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

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
        case .paused: ("Auto-restart off", .gray)
        }
    }

    private var tooltip: String {
        var lines = ["\(supervisor.statusText) · \(host.status)"]
        if let event = EventLog.shared.latest {
            let time = event.date.formatted(date: .omitted, time: .shortened)
            lines.append("last event \(time) · \(event.message)")
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            StatusDot(color: status.color, diameter: 7)
            Text(status.word)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .fixedSize()
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
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize()
                .help(debug.summary)
        }
    }
}

// MARK: - Update chip

/// The version chip is the whole update UI: it announces an update (click installs), confirms one
/// just landed (click acknowledges), and at rest flips into the Auto-Update switch on hover so the
/// setting costs no footer space.
private struct UpdateChip: View {
    let showsRestingVersion: Bool
    @AppStorage("autoUpdate", store: Preferences.app) private var autoUpdate = true
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
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
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
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
            .help("Updated to version \(justUpdated)")
        } else if let available = updates.availableVersion ?? updates.pendingVersion {
            Button { Task { await updates.updateNow() } } label: {
                Label("v\(available)", systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
            .help("Click to install version \(available)")
        } else if showsRestingVersion {
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
                .foregroundStyle(.secondary)
            }
            .buttonStyle(.footerChip)
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

// MARK: - Quit confirmation

/// What the ✕ opens: a strip that grows out of it over the footer and says what quitting takes
/// with it. The ✕ keeps its corner and turns red; Cancel takes the gear's place beside it. The
/// shape is Adrafinil's, so every menu-bar app of ours quits the same way.
struct QuitConfirmation: View {
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Quit Sevoflurane?")
                    .font(.system(.body, design: .rounded).weight(.semibold))
                Text("Steam closes with it, and so does any game it is running.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.sm) {
                Spacer(minLength: 0)
                FooterIconButton("Cancel", systemImage: "arrow.uturn.backward", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel")
                Button { NSApplication.shared.terminate(nil) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: Theme.footerControlHeight, height: Theme.footerControlHeight)
                        .contentShape(Circle())
                        .glassEffect(.regular.tint(.red).interactive(), in: Circle())
                }
                .buttonStyle(.plain)
                // Return, not ⌘Q: the ✕ under this strip holds ⌘Q, and it is what opened it.
                .keyboardShortcut(.defaultAction)
                .accessibilityLabel("Quit Sevoflurane")
                .help("Quit Sevoflurane and close Steam")
            }
        }
        .padding(Theme.Space.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        // Takes the taps, so the footer under it cannot be reached.
        .contentShape(.rect)
    }
}
