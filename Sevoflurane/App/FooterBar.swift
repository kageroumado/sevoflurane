import AppKit
import Propofol
import SwiftUI

/// The popover's bottom bar: the app's own state on the left — debug mode, its version, the way
/// back from a client that gave up — the renderer the games run on in the middle, and the app's
/// controls on the right.
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
    /// The renderer switch, between the app's state and its controls; absent
    /// while setup is unfinished.
    var graphics: GraphicsStore?
    /// The ✕: asks before quitting (``QuitConfirmation``), because quitting
    /// takes Steam and a running game down with it.
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }
    @AppStorage("autoUpdate", store: Preferences.app) private var autoUpdate = true

    private static var versionString: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0"
    }

    var body: some View {
        // One `GlassEffectContainer` over the whole bar: glass sampled per control picks up
        // whatever sits behind that spot, which is what made the chips and the glyph buttons look
        // like different materials. Zero blend distance, because the controls sit closer together
        // than any nonzero spacing allows before their glass pools into one shape.
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                if hasGivenUp, !isSettingUp {
                    Button("Recovery…") {
                        NSApp.sendAction(#selector(AppDelegate.showRecovery(_:)), to: nil, from: nil)
                    }
                    .buttonStyle(.footerChip)
                    .help("Open Recovery settings to restart or repair Steam, or save a report.")
                }
                DebugChip()
                UpdateChip()
                if let graphics, !isSettingUp {
                    RendererPicker(graphics: graphics)
                } else {
                    Spacer(minLength: 0)
                }
                if !isSettingUp {
                    actionsMenu
                    settingsButton
                }
                FooterIconButton(String(localized: "Quit Sevoflurane"), systemImage: "xmark", action: onQuit)
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
        let label = summary.map { String(localized: "Settings — \($0)") } ?? String(localized: "Settings")
        return FooterIconButton(label, systemImage: "gearshape") {
            NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
        }
        .help(summary.map { Text(verbatim: $0) } ?? Text("Settings"))
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
        FooterIconButton(String(localized: "More actions"), systemImage: "ellipsis") {}
            .allowsHitTesting(false)
            // The menu over it is the control; the drawing is not a second one.
            .accessibilityHidden(true)
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
                    Divider()
                    Toggle(isOn: Binding(
                        get: { autoUpdate },
                        set: { isOn in
                            autoUpdate = isOn
                            SilentUpdates.shared.setAutoInstall(isOn)
                        },
                    )) {
                        Label("Auto Update", systemImage: "arrow.down.circle")
                    }
                    .help("Install updates automatically while no game runs")
                    Text("Version \(Self.versionString)")
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("More actions")
            }
            .help("Reload, restart, the event log, and updates")
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

/// An update, while there is something to say about one: it announces an update (click installs),
/// confirms one just landed (click acknowledges), and reports a failure. At rest it is absent; the
/// version and the Auto Update switch live in the actions menu.
private struct UpdateChip: View {
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
                Label(justUpdated, systemImage: "checkmark")
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
            .help("Updated to version \(justUpdated)")
            .accessibilityLabel("Updated to version \(justUpdated)")
        } else if let available = updates.availableVersion ?? updates.pendingVersion {
            Button { Task { await updates.updateNow() } } label: {
                Label(available, systemImage: "arrow.down.circle.fill")
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
            .help("Click to install version \(available)")
            .accessibilityLabel("Install version \(available)")
        }
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
                Text("Steam and anything running in it close when Sevoflurane quits. For Steam problems, use the ⋯ menu to restart or open Recovery.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: Theme.Space.sm) {
                Spacer(minLength: 0)
                FooterIconButton(String(localized: "Cancel"), systemImage: "arrow.uturn.backward", action: onCancel)
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
