import Digoxin
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    let provisioner: Provisioner
    let store: StorageStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    /// The supervisor to stand down before an uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    /// The command-line tool as installed with these assistants, for the
    /// gallery; the Mac's own state otherwise.
    var automationFixture: [AgentIntegration.Harness]?

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            GeneralStartupSection(provisioner: provisioner, supervisor: supervisor, highlighted: highlighted)
            GeneralSteamSection(steam: steam, highlighted: highlighted)
            GeneralSteamPagesSection(steam: steam, highlighted: highlighted)
            GeneralCustomStyleSection(steam: steam, highlighted: highlighted)
            StreamerModeSection(steam: steam, highlighted: highlighted)
            GeneralPrivacySection(highlighted: highlighted)
            GeneralDiscordSection(highlighted: highlighted)
            GeneralAutomationSection(highlighted: highlighted, fixture: automationFixture)
            GeneralUninstallSection(
                provisioner: provisioner, store: store, supervisor: supervisor,
                highlighted: highlighted,
            )
        }
        .task { await store.measure() }
    }
}

// MARK: - Startup

private struct GeneralStartupSection: View {
    let provisioner: Provisioner
    let supervisor: ClientSupervisor?
    let highlighted: SettingsAnchor?
    @State private var openAtLogin = false

    var body: some View {
        SettingsSection(title: "Startup") {
            SettingsToggle(title: "Open at login", isOn: $openAtLogin)
                .onChange(of: openAtLogin) { _, enabled in
                    // Reading the machine's value in onAppear lands here too.
                    guard enabled != provisioner.openAtLogin else { return }
                    provisioner.setOpenAtLogin(enabled)
                }
                .highlightable(.generalOpenAtLogin, highlighted: highlighted)
                .onAppear { openAtLogin = provisioner.openAtLogin }
            if let supervisor {
                AutoRestartRow(supervisor: supervisor)
            }
            GamesFolderRow()
        }
    }
}

/// The Games folder in the Dock (``GamesFolder``, ``DockTiles``): every game's
/// own icon, the last played on top.
private struct GamesFolderRow: View {
    /// The switch as last set here; the Dock's own record until then.
    @State private var kept: Bool?

    var body: some View {
        SettingsToggle(
            title: "Games folder in the Dock",
            caption: String(localized: "Every game that has run, the last played on top."),
            help: .gamesFolder,
            isOn: Binding(
                get: { kept ?? false },
                set: { isOn in
                    kept = isOn
                    Task.detached(name: isOn ? "Keep the Games folder in the Dock" : "Take the Games folder out of the Dock") {
                        if isOn {
                            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
                            DockTiles.keepFolder(GamesFolder.root, label: GamesFolder.label)
                        } else {
                            DockTiles.removeFolder(GamesFolder.root)
                        }
                    }
                },
            ),
        )
        .task {
            kept = await Self.readKept()
        }
    }

    @concurrent
    private nonisolated static func readKept() async -> Bool {
        DockTiles.isFolderKept(GamesFolder.root)
    }
}

/// Whether the supervisor keeps Steam running: the daemon's state, which holds
/// until the background helper restarts.
private struct AutoRestartRow: View {
    let supervisor: ClientSupervisor

    var body: some View {
        SettingsToggle(
            title: "Auto-restart Steam",
            caption: String(localized: "When Steam crashes or stops responding."),
            isOn: Binding(
                get: { supervisor.health != .paused },
                set: { supervisor.setAutoRestart($0) },
            ),
        )
    }
}

// MARK: - Steam

private struct GeneralSteamSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?

    var body: some View {
        SettingsSection(title: "Steam") {
            if let steam {
                SettingsAction(
                    title: "Steam settings",
                    caption: String(localized: "Downloads, controllers, and the Steam interface."),
                ) {
                    Button("Open Steam Settings") { steam.openSteamSettings() }
                }
                .highlightable(.generalSteamSettings, highlighted: highlighted)
            }
            SteamLinksRow()
                .highlightable(.generalSteamLinks, highlighted: highlighted)
        }
    }
}

/// Which app macOS opens a `steam://` link with. macOS has a way to take the
/// links and none to give them back, so the row is a button, and a state once
/// they come here.
private struct SteamLinksRow: View {
    @State private var steamLinksComeHere = SteamLinks.comeHere

    var body: some View {
        SettingsAction(title: "Steam links", caption: caption) {
            if steamLinksComeHere {
                SettingsStatus(.done, String(localized: "Open in Sevoflurane"))
            } else {
                Button("Open Steam Links in Sevoflurane") {
                    Task(name: "Claim steam links") { steamLinksComeHere = await SteamLinks.claim() }
                }
            }
        }
    }

    private var caption: String {
        steamLinksComeHere
            ? String(localized: "Install buttons and invitations on the web.")
            : String(localized: "Install buttons and invitations on the web open in \(SteamLinks.handlerName ?? String(localized: "another app")).")
    }
}

// MARK: - The Steam pages

private struct GeneralSteamPagesSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var compatibilityStrip = true
    @State private var offersSteamForMac = false

    var body: some View {
        SettingsSection(title: "Steam pages") {
            SettingsToggle(
                title: "Mac compatibility strip",
                caption: String(localized: "Game pages show how each game runs on a Mac."),
                help: .compatibilityStrip,
                isOn: $compatibilityStrip,
            )
            .onChange(of: compatibilityStrip) { _, enabled in
                // Reading the preference in onAppear lands here too.
                guard enabled != Preferences.compatibilityStrip else { return }
                Preferences.compatibilityStrip = enabled
                steam?.applyCompatibilityStrip()
            }
            .highlightable(.generalCompatStrip, highlighted: highlighted)
            .onAppear { compatibilityStrip = Preferences.compatibilityStrip }
            if Engine.running.supportsSteamPlayMacOS {
                SettingsToggle(
                    title: "Steam for Mac",
                    caption: String(localized: "Offers Valve\u{2019}s Steam for Mac for a game\u{2019}s macOS version."),
                    help: .steamForMac,
                    isOn: $offersSteamForMac,
                )
                .onChange(of: offersSteamForMac) { _, enabled in
                    // Reading the preference in onAppear lands here too.
                    guard enabled != Preferences.offersSteamForMac else { return }
                    Preferences.offersSteamForMac = enabled
                    steam?.applyCompatibilityStrip()
                }
                .onAppear { offersSteamForMac = Preferences.offersSteamForMac }
            }
        }
    }
}

// MARK: - Custom style

/// The user's own stylesheets for Steam, from the Styles folder.
private struct GeneralCustomStyleSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var isOn = false
    @State private var onWebPages = false
    @State private var folderFailure: String?

    var body: some View {
        SettingsSection(title: "Custom style") {
            SettingsToggle(
                title: "Style Steam with CSS",
                caption: String(localized: "CSS files in the Styles folder restyle Steam\u{2019}s windows."),
                help: .customStyle,
                isOn: $isOn,
            )
            .onChange(of: isOn) { _, enabled in
                // Reading the preference in onAppear lands here too.
                guard enabled != Preferences.userStyles else { return }
                Preferences.userStyles = enabled
                steam?.applyUserStyles()
            }
            .highlightable(.generalCustomStyle, highlighted: highlighted)
            SettingsToggle(title: "Also style store and community pages", isOn: $onWebPages)
                .disabled(!isOn)
                .onChange(of: onWebPages) { _, enabled in
                    guard enabled != Preferences.userStylesOnWebPages else { return }
                    Preferences.userStylesOnWebPages = enabled
                    steam?.applyUserStyles()
                }
            SettingsAction(title: "Styles folder", state: .failure(ifPresent: folderFailure)) {
                Button("Show in Finder") { openFolder() }
            }
        }
        .onAppear {
            isOn = Preferences.userStyles
            onWebPages = Preferences.userStylesOnWebPages
        }
    }

    private func openFolder() {
        do {
            try UserStyles.prepareFolder()
            folderFailure = nil
            NSWorkspace.shared.open(UserStyles.folder)
        } catch {
            folderFailure = error.localizedDescription
        }
    }
}

// MARK: - Community database

/// Whether closed runs go to the community database, what has gone, and the way
/// to take it back.
private struct GeneralPrivacySection: View {
    let highlighted: SettingsAnchor?
    @State private var shares = false
    @State private var state = StatsStore.State()
    @State private var isConfirmingDelete = false
    @State private var deleteFailure: String?

    var body: some View {
        SettingsSection(title: "Privacy") {
            SettingsToggle(
                title: "Share run statistics",
                caption: sentLine
                    ?? String(localized: "Each closed game\u{2019}s frame rate and settings go to the public game database."),
                help: .shareRuns,
                isOn: $shares,
            )
            .onChange(of: shares) { _, shares in
                guard Preferences.sharesRunStats != shares else { return }
                SharingConsent.store(shares)
            }
            .highlightable(.generalShareRuns, highlighted: highlighted)
            SettingsDisclosure(title: "Exactly what is sent") {
                SettingsCodeBlock(text: SharedRunPreview.json)
            }
            if state.registered != nil || state.sentRuns > 0 {
                SettingsAction(title: "Shared runs", state: .failure(ifPresent: deleteFailure)) {
                    Button("Delete What I Shared…") { isConfirmingDelete = true }
                }
            }
            SettingsAction(title: "Game database", caption: "How games run on other Macs, from shared runs.") {
                Button("Open Website") { NSWorkspace.shared.open(GameDatabase.pageURL) }
            }
            GeneralUsageRow()
        }
        .onAppear(perform: reload)
        .confirmationDialog(
            "Delete every run this Mac shared?", isPresented: $isConfirmingDelete,
        ) {
            Button("Delete", role: .destructive) { delete() }
        } message: {
            Text("The database deletes these runs. The next run you share uses a new, unrelated identity.")
        }
    }

    private var sentLine: String? {
        guard state.sentRuns > 0, let last = state.lastSent else {
            return state.lastError.map { String(localized: "Not sent yet: \($0)") }
        }
        let when = last.formatted(.relative(presentation: .named))
        return String(localized: "\(state.sentRuns) runs shared, the last one \(when).")
    }

    private func reload() {
        shares = Preferences.sharesRunStats == true
        state = StatsStore.readState()
    }

    private func delete() {
        Task {
            do {
                try await StatsUploader.shared.deleteShared()
                deleteFailure = nil
            } catch {
                deleteFailure = String(localized: "The database is unavailable. Try again later.")
            }
            reload()
        }
    }
}

// MARK: - Usage count

/// Whether this Mac is counted among Sevoflurane's users, and whether
/// Sevoflurane's own crashes are reported.
private struct GeneralUsageRow: View {
    @State private var tier = ConsentTier.off
    @State private var status: DigoxinStatus = .off

    var body: some View {
        SettingsPicker(
            title: "Count this Mac",
            caption: statusLine ?? String(localized: "One anonymous check-in on each day you use Sevoflurane."),
            help: .usageCount,
            selection: $tier,
        ) {
            Text("Off").tag(ConsentTier.off)
            Text("Counting").tag(ConsentTier.counting)
            Text("Counting and crash reports").tag(ConsentTier.crashReports)
        }
        .onChange(of: tier) { _, tier in
            // Reading the preference in the task lands here too.
            guard Preferences.usageCounting != tier else { return }
            UsageCounting.choose(tier)
            Task { await refreshStatus() }
        }
        .task {
            tier = Preferences.usageCounting ?? .off
            await refreshStatus()
        }
    }

    private var statusLine: String? {
        switch status {
        case .deletionPending: String(localized: "Deleting what this Mac sent\u{2026}")
        case .secureEnclaveUnavailable: String(localized: "This Mac has no Secure Enclave, so nothing is sent.")
        case let .failing(reason): String(localized: "Not sent yet: \(reason)")
        case .off, .waiting, .registered: nil
        }
    }

    private func refreshStatus() async {
        status = await UsageCounting.client.status
    }
}

// MARK: - Discord

private struct GeneralDiscordSection: View {
    let highlighted: SettingsAnchor?
    @State private var discordBridge = false
    @State private var discordPresence = false

    /// Whether this engine ships the relay that carries a game's own Discord
    /// traffic out of the bottle.
    private var hasDiscordBridge: Bool {
        Engine.active.discordBridge != nil
    }

    var body: some View {
        SettingsSection(
            title: "Discord",
            footer: "A game\u{2019}s own presence comes through a relay in the bottle.",
            reach: .clientRestart,
        ) {
            SettingsToggle(
                title: "Show what you play in Discord",
                caption: String(localized: "Each game under its own name and box art."),
                isOn: $discordPresence,
            )
            .onChange(of: discordPresence) { _, enabled in
                Preferences.discordPresence = enabled
            }
            .highlightable(.generalDiscordPresence, highlighted: highlighted)
            SettingsToggle(
                title: "Discord presence in games",
                caption: hasDiscordBridge
                    ? String(localized: "Games with their own Discord support show their status.")
                    : String(localized: "Only the built-in engine includes the Discord relay."),
                isOn: $discordBridge,
            )
            .disabled(!hasDiscordBridge)
            .onChange(of: discordBridge) { _, enabled in
                Preferences.discordBridge = enabled
            }
            .highlightable(.generalDiscordBridge, highlighted: highlighted)
        }
        .onAppear {
            discordBridge = Preferences.discordBridge
            discordPresence = Preferences.discordPresence
        }
    }
}

// MARK: - Automation

private struct AgentRow: Identifiable {
    let harness: AgentIntegration.Harness
    var registered: Bool
    var busy = false
    var error: String?
    var id: String {
        harness.id
    }
}

/// The command-line tool and, once installed, the assistants that can reach
/// Steam through it.
private struct GeneralAutomationSection: View {
    let highlighted: SettingsAnchor?
    let fixture: [AgentIntegration.Harness]?
    @State private var cliInstalled = false
    @State private var agents: [AgentRow] = []

    var body: some View {
        SettingsSection(
            title: "Automation",
            footer: cliInstalled ? "Allow each assistant to control Steam through MCP." : nil,
        ) {
            CommandLineToolRow(installed: $cliInstalled, finished: refreshAgents)
                .highlightable(.generalCli, highlighted: highlighted)
                .task {
                    if let fixture {
                        cliInstalled = true
                        agents = fixture.enumerated().map { AgentRow(harness: $1, registered: $0 == 0) }
                    } else {
                        cliInstalled = AgentIntegration.isCLIInstalled
                        await refreshAgents()
                    }
                }
            if cliInstalled {
                if agents.isEmpty {
                    SettingsMessage(text: "No supported AI assistant is installed.")
                } else {
                    ForEach($agents) { $row in
                        AgentToggleRow(row: $row)
                            .highlightable(
                                .generalAgents, highlighted: highlighted,
                                isScrollTarget: row.id == agents.first?.id,
                            )
                    }
                }
                SettingsCode(title: "Other MCP assistants", code: AgentIntegration.manualCommand)
            }
        }
    }

    private func refreshAgents() async {
        var rows: [AgentRow] = []
        for harness in AgentIntegration.detectedHarnesses {
            await rows.append(AgentRow(harness: harness, registered: AgentIntegration.isRegistered(harness)))
        }
        agents = rows
    }
}

private struct CommandLineToolRow: View {
    @Binding var installed: Bool
    /// Runs after an install or a removal, whatever its outcome.
    let finished: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        SettingsAction(
            title: "Command-line tool", caption: caption, state: .failure(ifPresent: error), isWorking: busy,
        ) {
            Button(installed ? "Remove Tool" : "Install Tool…") {
                busy = true
                Task(name: installed ? "Remove the command-line tool" : "Install the command-line tool") {
                    if installed {
                        await AgentIntegration.remove()
                        error = nil
                    } else {
                        error = await AgentIntegration.installCLI()
                    }
                    installed = AgentIntegration.isCLIInstalled
                    await finished()
                    busy = false
                }
            }
            .disabled(busy)
        }
    }

    private var caption: String {
        installed
            ? String(localized: "Installed at /usr/local/bin/sevo.")
            : String(localized: "The sevo command for Terminal and MCP. Asks for an administrator password.")
    }
}

private struct AgentToggleRow: View {
    @Binding var row: AgentRow

    var body: some View {
        SettingsToggle(
            title: "\(row.harness.displayName)",
            state: .failure(ifPresent: row.error),
            isWorking: row.busy,
            isOn: Binding(
                get: { row.registered },
                set: { enabled in flip(to: enabled) },
            ),
        )
        .disabled(row.busy)
        .help(row.harness.configDescription)
    }

    private func flip(to enabled: Bool) {
        row.busy = true
        row.error = nil
        let harness = row.harness
        Task(name: "\(enabled ? "Connect" : "Disconnect") \(harness.displayName)") {
            let failure = enabled
                ? await AgentIntegration.register(harness)
                : await AgentIntegration.unregister(harness)
            row.error = failure
            row.registered = await AgentIntegration.isRegistered(harness)
            row.busy = false
        }
    }
}

// MARK: - Uninstall

private struct GeneralUninstallSection: View {
    let provisioner: Provisioner
    let store: StorageStore
    let supervisor: ClientSupervisor?
    let highlighted: SettingsAnchor?
    @State private var confirmingUninstall = false

    var body: some View {
        SettingsSection(title: "Uninstall") {
            SettingsAction(
                title: "Sevoflurane",
                caption: String(localized: "Removes the app, its engines, and toolkits. Removing games is your choice."),
            ) {
                Button("Uninstall Sevoflurane…", role: .destructive) { confirmingUninstall = true }
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
