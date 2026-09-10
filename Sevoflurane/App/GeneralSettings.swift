import Propofol
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    let provisioner: Provisioner
    let store: StorageStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    /// The supervisor to stand down before an uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    @State private var openAtLogin = false
    @State private var cliInstalled = false
    @State private var cliBusy = false
    @State private var cliError: String?
    @State private var agents: [AgentRow] = []
    @State private var confirmingUninstall = false
    @State private var discordBridge = false
    @State private var discordPresence = false

    /// One detected AI assistant: its registration state, and the in-flight
    /// and failure state of the last flip.
    private struct AgentRow: Identifiable {
        let harness: AgentIntegration.Harness
        var registered: Bool
        var busy = false
        var error: String?
        var id: String {
            harness.id
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.switch)
                .onChange(of: openAtLogin) { _, enabled in
                    provisioner.setOpenAtLogin(enabled)
                }
                .highlightable(.generalOpenAtLogin, highlighted: highlighted)
                if let steam {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steam settings")
                            Text("Downloads, controllers, and the Steam interface.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open…") { steam.openSteamSettings() }
                    }
                    .highlightable(.generalSteamSettings, highlighted: highlighted)
                }
            }
            Section {
                cliRow
                if cliInstalled {
                    if agents.isEmpty {
                        Text("No supported AI assistant is installed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($agents) { $row in
                            agentRow($row)
                        }
                    }
                    manualCommandRow
                }
            } header: {
                Text("Automation")
            } footer: {
                if cliInstalled {
                    Text("Let each assistant control Steam through MCP.")
                }
            }
            discordSection
            uninstallSection
        }
        .formStyle(.grouped)
        .onAppear {
            openAtLogin = provisioner.openAtLogin
            cliInstalled = AgentIntegration.isCLIInstalled
            discordBridge = Preferences.discordBridge
            discordPresence = Preferences.discordPresence
            refreshAgents()
        }
        .task { await store.measure() }
    }

    // MARK: - Discord

    /// Whether this engine ships the relay that carries a game's own Discord
    /// traffic out of the bottle.
    private var hasDiscordBridge: Bool {
        Engine.active.discordBridge != nil
    }

    private var discordSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Discord presence in games", isOn: $discordBridge)
                    .toggleStyle(.switch)
                    .disabled(!hasDiscordBridge)
                    .onChange(of: discordBridge) { _, enabled in
                        Preferences.discordBridge = enabled
                    }
                Text(hasDiscordBridge
                    ? "Games with their own Discord support show their status. Restart Steam to apply a change."
                    : "Only the built-in engine carries the Discord relay. Switch to it in Engine.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalDiscordBridge, highlighted: highlighted)
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show what you play in Discord", isOn: $discordPresence)
                    .toggleStyle(.switch)
                    .disabled(!DiscordPresence.isConfigured)
                    .onChange(of: discordPresence) { _, enabled in
                        Preferences.discordPresence = enabled
                    }
                Text(DiscordPresence.isConfigured
                    ? "Sevoflurane shows the game's name and artwork while it runs."
                    : "Needs a Discord application id.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalDiscordPresence, highlighted: highlighted)
        } header: {
            Text("Discord")
        }
    }

    // MARK: - Automation

    private var cliRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command-line tool")
                Text(cliInstalled
                    ? "Installed at /usr/local/bin/sevo."
                    : "Adds sevo for Terminal and MCP. Needs an administrator password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let cliError {
                    Text(cliError).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            if cliBusy {
                ProgressView().controlSize(.small)
            }
            Button(cliInstalled ? "Remove" : "Install…") {
                cliBusy = true
                Task {
                    if cliInstalled {
                        await AgentIntegration.remove()
                        cliError = nil
                    } else {
                        cliError = await AgentIntegration.installCLI()
                    }
                    cliInstalled = AgentIntegration.isCLIInstalled
                    refreshAgents()
                    cliBusy = false
                }
            }
            .disabled(cliBusy)
        }
        .highlightable(.generalCli, highlighted: highlighted)
    }

    private func agentRow(_ row: Binding<AgentRow>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.wrappedValue.harness.displayName)
                        .help(row.wrappedValue.harness.configDescription)
                }
                Spacer()
                if row.wrappedValue.busy {
                    ProgressView().controlSize(.small)
                }
                Toggle(row.wrappedValue.harness.displayName, isOn: Binding(
                    get: { row.wrappedValue.registered },
                    set: { enabled in flip(row, to: enabled) },
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(row.wrappedValue.busy)
            }
            if let error = row.wrappedValue.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .highlightable(.generalAgents, highlighted: highlighted)
    }

    /// For every agent that speaks MCP but isn't in the list: the command,
    /// ready to paste.
    private var manualCommandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other MCP assistants")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Text(AgentIntegration.manualCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: AgentIntegration.manualCommand)
            }
            .padding(Theme.Space.sm)
            .background(.quaternary.opacity(0.6), in: Theme.innerShape)
        }
    }

    private func flip(_ row: Binding<AgentRow>, to enabled: Bool) {
        row.wrappedValue.busy = true
        row.wrappedValue.error = nil
        let harness = row.wrappedValue.harness
        Task(name: "\(enabled ? "Connect" : "Disconnect") \(harness.displayName)") {
            let failure = enabled
                ? await AgentIntegration.register(harness)
                : await AgentIntegration.unregister(harness)
            row.wrappedValue.error = failure
            row.wrappedValue.registered = AgentIntegration.isRegistered(harness)
            row.wrappedValue.busy = false
        }
    }

    private func refreshAgents() {
        agents = AgentIntegration.detectedHarnesses.map {
            AgentRow(harness: $0, registered: AgentIntegration.isRegistered($0))
        }
    }

    // MARK: - Uninstall

    private var uninstallSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Sevoflurane").font(.headline)
                    Text("Removes Sevoflurane and the engines and toolkits it downloaded. You choose whether games go too.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                    .disabled(store.isUninstalling)
            }
            .highlightable(.generalUninstall, highlighted: highlighted)
        }
        .confirmationDialog(
            "Uninstall Sevoflurane?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible,
        ) {
            Button("Uninstall, Keep Games", role: .destructive) {
                uninstall(includingBottle: false)
            }
            Button("Uninstall Everything", role: .destructive) {
                uninstall(includingBottle: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Steam closes. Sevoflurane removes the engines and toolkits it downloaded, resets its settings, and disconnects assistants.\n\nKeep Games leaves Steam and its \(StorageSettings.size(bottleBytes)) of files in place. Uninstall Everything moves those files to the Trash, local saves included.\n\nSevoflurane moves itself to the Trash and quits. Your Steam account and cloud saves stay.")
        }
    }

    private var bottleBytes: Int64 {
        store.entries
            .filter { ["bottle", "client", "games", "caches"].contains($0.id) }
            .map { max(0, $0.bytes) }
            .reduce(0, +)
    }

    private func uninstall(includingBottle: Bool) {
        Task(name: "Uninstall") {
            await store.uninstall(
                includingBottle: includingBottle, provisioner: provisioner,
                supervisor: supervisor,
            )
            NSApp.terminate(nil)
        }
    }
}

/// A borderless copy button that flips to a checkmark for a moment after
/// copying.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeInOut(duration: 0.3)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}
