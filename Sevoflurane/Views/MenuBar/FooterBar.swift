import AppKit
import Propofol
import SwiftUI

/// The popover's bottom bar: the app's state on the left (debug mode, an update, the way back
/// from a client that gave up), the renderer in the middle, and the controls on the right. Only
/// the gear and the close box are glyphs; every other action is named in the actions menu.
struct FooterBar: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    /// While setup is unfinished the bar keeps only the version and Quit.
    var isSettingUp = false
    /// The renderer switch; absent while setup is unfinished.
    var graphics: GraphicsStore?
    /// The ✕: asks first (``QuitConfirmation``), because quitting takes Steam
    /// and a running game down.
    var onQuit: () -> Void = { NSApplication.shared.terminate(nil) }

    var body: some View {
        // One `GlassEffectContainer` over the whole bar, so the chips and glyph buttons
        // sample one material. Zero blend distance, because the controls sit closer than any
        // nonzero spacing allows before their glass pools.
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

    /// The gear, with a dot when the release feed has an engine or renderer version this Mac lacks.
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

    /// `Menu` comes out narrower and darker than the glass circles however it is styled, so the
    /// visible control is a real `FooterIconButton` and the menu is a transparent layer over it
    /// that takes the click.
    private var actionsMenu: some View {
        FooterIconButton(String(localized: "More actions"), systemImage: "ellipsis") {}
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .overlay {
                Menu {
                    FooterActionItems(host: host, supervisor: supervisor)
                } label: {
                    Color.clear.contentShape(.rect)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .accessibilityLabel("More actions")
            }
            .help("Reload, restart, the event log, and updates")
    }
}

// MARK: - Actions menu

/// The items of the footer's actions menu: the client's restart and force
/// rungs, the logs, Streamer Mode, and updates.
private struct FooterActionItems: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @AppStorage("autoUpdate", store: Preferences.app) private var autoUpdate = true
    @AppStorage(StreamerMode.isOnKey, store: Preferences.shared) private var streamerMode = false

    private static var versionString: String {
        AppVersion.displayed(from: Bundle.main.infoDictionary, fallback: "0.0")
    }

    var body: some View {
        Button("Reload Steam UI", systemImage: "arrow.clockwise") { host.reloadAskedByUser() }
        Button("Restart Steam Client", systemImage: "arrow.triangle.2.circlepath") {
            supervisor.restartNow()
        }
        // Steam restarts leave the Windows session booted; this
        // reboots it too.
        Button("Restart Windows", systemImage: "power.circle") {
            supervisor.restartWindowsNow()
        }
        Divider()
        // The force rungs, for when a graceful restart is what is
        // stuck.
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
            NSApp.sendAction(#selector(AppDelegate.showEventLog(_:)), to: nil, from: nil)
        }
        debugModeItem
        Toggle(isOn: Binding(
            get: { streamerMode },
            set: { isOn in
                StreamerMode.isOn = isOn
                host.applyStreamerMode()
            },
        )) {
            Label("Streamer Mode", systemImage: "eye.slash")
        }
        .help("Hides your Steam name, picture, wallet balance and friends in every Steam window, for recording and streaming.")
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
        Button("Check for Updates…", systemImage: "arrow.clockwise") {
            SilentUpdates.shared.checkOrInstallFromMenu()
        }
        Text("Version \(Self.versionString)")
    }

    /// The playtest switch, and, while a client is up, the restart that carries it to the
    /// client. The engine half is read at a program's start, so a running Steam keeps the
    /// channels it booted with.
    @ViewBuilder private var debugModeItem: some View {
        let debug = DebugModeSwitch.shared
        Toggle(isOn: Binding(get: { debug.isOn }, set: { debug.set($0) })) {
            Label("Debug Mode", systemImage: "ladybug")
        }
        // Whole literals: joined with `+` they become a `String`, which `help` shows unlocalized.
        .help(Engine.active.supportsEnvFiles
            ? Text("Logs library loads, renderer errors, and the engine's frame trail. Stops when the app quits.")
            : Text("Logs more of what Sevoflurane does. The engine's own logging needs Dormison. Stops when the app quits."))
        if debug.isOn, isClientUp {
            Button("Restart Steam to Apply Debug Mode") {
                supervisor.restartNow(reason: "debug mode")
            }
        }
    }

    /// Whether a client is running under the environment debug mode just changed.
    private var isClientUp: Bool {
        switch supervisor.health {
        case .healthy, .degraded, .waitingForSignIn: true
        case .starting, .launching, .restarting, .gaveUp, .paused: false
        }
    }
}

// MARK: - Debug chip

/// Shown only while debug mode is on; its tooltip carries the logs' sizes.
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

/// An update, while there is something to say: one available (click installs), one just landed
/// (click acknowledges), or a failure. Absent at rest.
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
        if let justUpdated = updates.justUpdatedVersion.map(AppVersion.display) {
            Button { updates.acknowledgeUpdate() } label: {
                Label(justUpdated, systemImage: "checkmark")
                    .foregroundStyle(Theme.onAccent)
            }
            .buttonStyle(.footerChipProminent)
            .help("Updated to version \(justUpdated)")
            .accessibilityLabel("Updated to version \(justUpdated)")
        } else if let available = (updates.availableVersion ?? updates.pendingVersion).map(AppVersion.display) {
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

/// What the ✕ opens: a strip over the footer that says what quitting takes with it. The ✕
/// turns red and Cancel takes the gear's place, the shape every kageroumado menu-bar app quits
/// with (Adrafinil's).
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
