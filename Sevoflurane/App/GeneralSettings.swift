import Digoxin
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

    var body: some View {
        Form {
            GeneralStartupSection(
                provisioner: provisioner, steam: steam, supervisor: supervisor, highlighted: highlighted,
            )
            GeneralAutomationSection(highlighted: highlighted)
            GeneralSteamPagesSection(steam: steam, highlighted: highlighted)
            GeneralCustomStyleSection(steam: steam, highlighted: highlighted)
            StreamerModeSection(steam: steam, highlighted: highlighted)
            GeneralCommunitySection(highlighted: highlighted)
            GeneralUsageSection()
            GeneralDiscordSection(highlighted: highlighted)
            GeneralUninstallSection(
                provisioner: provisioner, store: store, supervisor: supervisor,
                highlighted: highlighted,
            )
        }
        .formStyle(.grouped)
        .task { await store.measure() }
    }
}

// MARK: - Startup and Steam

/// Open at login, the door to Steam's own settings, and where `steam://`
/// links go.
private struct GeneralStartupSection: View {
    let provisioner: Provisioner
    let steam: SteamActions?
    let supervisor: ClientSupervisor?
    let highlighted: SettingsAnchor?
    @State private var openAtLogin = false

    var body: some View {
        Section {
            Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.switch)
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
            if let steam {
                SteamSettingsRow(steam: steam)
                    .highlightable(.generalSteamSettings, highlighted: highlighted)
            }
            SteamLinksRow()
        }
    }
}

/// Whether the supervisor keeps Steam running. It holds until Sevoflurane's
/// background helper restarts, so it says what off costs rather than
/// pretending to be a stored preference.
private struct AutoRestartRow: View {
    let supervisor: ClientSupervisor

    var body: some View {
        Toggle(isOn: Binding(
            get: { supervisor.health != .paused },
            set: { supervisor.setAutoRestart($0) },
        )) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Auto-restart Steam")
                Text("Automatically restarts Steam if it crashes or stops responding.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .toggleStyle(.switch)
    }
}

/// The button that opens the Steam client's own settings.
private struct SteamSettingsRow: View {
    let steam: SteamActions

    var body: some View {
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
    }
}

/// Which app `steam://` links open in, and the button that claims them.
private struct SteamLinksRow: View {
    @State private var steamLinksComeHere = SteamLinks.comeHere

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Steam links")
                Text(steamLinksComeHere
                    ? InterfaceCopy.localized("Install buttons and invitations on the web open here.")
                    : String(localized: "Install buttons and invitations on the web open in \(SteamLinks.handlerName ?? String(localized: "another app"))."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !steamLinksComeHere {
                Button("Open Them Here") {
                    Task(name: "Claim steam links") { steamLinksComeHere = await SteamLinks.claim() }
                }
            }
        }
    }
}

// MARK: - Automation

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

/// The command-line tool and, once it is installed, the assistants that can
/// reach Steam through it.
private struct GeneralAutomationSection: View {
    let highlighted: SettingsAnchor?
    @State private var cliInstalled = false
    @State private var agents: [AgentRow] = []

    var body: some View {
        Section {
            CommandLineToolRow(installed: $cliInstalled, finished: refreshAgents)
                .highlightable(.generalCli, highlighted: highlighted)
                .task {
                    cliInstalled = AgentIntegration.isCLIInstalled
                    await refreshAgents()
                }
            if cliInstalled {
                if agents.isEmpty {
                    Text("No supported AI assistant is installed.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach($agents) { $row in
                        AgentToggleRow(row: $row)
                            .highlightable(.generalAgents, highlighted: highlighted)
                    }
                }
                ManualCommandRow()
            }
        } header: {
            Text("Automation")
        } footer: {
            if cliInstalled {
                Text("Allow each assistant to control Steam through MCP.")
            }
        }
    }

    /// Reads the assistants' configs.
    private func refreshAgents() async {
        var rows: [AgentRow] = []
        for harness in AgentIntegration.detectedHarnesses {
            await rows.append(AgentRow(harness: harness, registered: AgentIntegration.isRegistered(harness)))
        }
        agents = rows
    }
}

/// Installs and removes `sevo`, with the progress and the failure of the
/// last attempt.
private struct CommandLineToolRow: View {
    @Binding var installed: Bool
    /// Runs after an install or a removal, whatever its outcome.
    let finished: () async -> Void
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command-line tool")
                Text(installed
                    ? "Installed at /usr/local/bin/sevo."
                    : "Installs the sevo command for Terminal and MCP. Requires an administrator password.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let error {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            if busy {
                ProgressView().controlSize(.small)
            }
            Button(installed ? "Remove" : "Install…") {
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
}

/// One assistant and the switch that registers Sevoflurane with it.
private struct AgentToggleRow: View {
    @Binding var row: AgentRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.harness.displayName)
                        .help(row.harness.configDescription)
                }
                Spacer()
                if row.busy {
                    ProgressView().controlSize(.small)
                }
                Toggle(row.harness.displayName, isOn: Binding(
                    get: { row.registered },
                    set: { enabled in flip(to: enabled) },
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(row.busy)
            }
            if let error = row.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
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

/// For every agent that speaks MCP but isn't in the list: the command,
/// ready to paste.
private struct ManualCommandRow: View {
    var body: some View {
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
}

// MARK: - The Steam pages

/// What Sevoflurane adds to Steam's own pages.
private struct GeneralSteamPagesSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var compatibilityStrip = true

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Mac compatibility strip", isOn: $compatibilityStrip)
                    .toggleStyle(.switch)
                    .onChange(of: compatibilityStrip) { _, enabled in
                        // Reading the preference in onAppear lands here too.
                        guard enabled != Preferences.compatibilityStrip else { return }
                        Preferences.compatibilityStrip = enabled
                        steam?.applyCompatibilityStrip()
                    }
                Text("A game's library and store pages say how it runs on a Mac, whether it has a macOS version, and what its anti-cheat does. The library badges every game, and its Mac button keeps only the games that play. Sevoflurane's own players' runs come first where there are enough.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalCompatStrip, highlighted: highlighted)
            .onAppear { compatibilityStrip = Preferences.compatibilityStrip }
        } header: {
            Text("Steam pages")
        }
    }
}

// MARK: - Custom style

/// The user's own stylesheets for Steam, from the Styles folder, and the
/// selectors in Steam's UI that hold across its updates.
private struct GeneralCustomStyleSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var isOn = false
    @State private var onWebPages = false
    @State private var folderFailure: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Style Steam with CSS", isOn: $isOn)
                    .toggleStyle(.switch)
                    .onChange(of: isOn) { _, enabled in
                        // Reading the preference in onAppear lands here too.
                        guard enabled != Preferences.userStyles else { return }
                        Preferences.userStyles = enabled
                        steam?.applyUserStyles()
                    }
                Text("Every CSS file in the Styles folder styles Steam\u{2019}s windows, in name order. Saving a file restyles them right away.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalCustomStyle, highlighted: highlighted)
            Toggle("Also style store and community pages", isOn: $onWebPages)
                .toggleStyle(.switch)
                .disabled(!isOn)
                .onChange(of: onWebPages) { _, enabled in
                    guard enabled != Preferences.userStylesOnWebPages else { return }
                    Preferences.userStylesOnWebPages = enabled
                    steam?.applyUserStyles()
                }
            HStack {
                if let folderFailure {
                    Text(folderFailure)
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Spacer()
                Button("Open Styles Folder") { openFolder() }
            }
        } header: {
            Text("Custom style")
        } footer: {
            Text("Most of Steam\u{2019}s class names change with each Steam update. .DesktopUI, .TitleBar, the .Dialog classes, the .SVGIcon_ icons and ARIA roles stay the same; README.css in the folder lists them.")
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

/// Whether closed runs go to the community database, what has gone, and the
/// way to take it back.
private struct GeneralCommunitySection: View {
    let highlighted: SettingsAnchor?
    @State private var shares = false
    @State private var state = StatsStore.State()
    @State private var isConfirmingDelete = false
    @State private var deleteFailure: String?

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Share run statistics", isOn: $shares)
                    .toggleStyle(.switch)
                    .onChange(of: shares) { _, shares in
                        guard Preferences.sharesRunStats != shares else { return }
                        Preferences.sharesRunStats = shares
                        if shares {
                            Task.detached(name: "Send queued shared runs") { await StatsUploader.shared.flush() }
                        } else {
                            StatsStore.writeQueue([])
                        }
                    }
                Text("After a game closes, its frame rate, resolution, engine and settings go to the public Sevoflurane game database with your Mac\u{2019}s model and chip. Nothing names you, your Mac or your account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let sent = sentLine {
                    Text(sent)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .highlightable(.generalShareRuns, highlighted: highlighted)
            SharedRunPreview()
            if state.registered != nil || state.sentRuns > 0 {
                HStack {
                    Button("Delete What I Shared\u{2026}") { isConfirmingDelete = true }
                    if let deleteFailure {
                        Text(deleteFailure)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Community")
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

/// Whether this Mac is counted among Sevoflurane's users, what that sends,
/// and whether Sevoflurane's own crashes are reported.
private struct GeneralUsageSection: View {
    @State private var tier = ConsentTier.off
    @State private var status: DigoxinStatus = .off

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Picker("Count this Mac", selection: $tier) {
                    Text("Off").tag(ConsentTier.off)
                    Text("Counting").tag(ConsentTier.counting)
                    Text("Counting and crash reports").tag(ConsentTier.crashReports)
                }
                .onChange(of: tier) { _, tier in
                    // Reading the preference in onAppear lands here too.
                    guard Preferences.usageCounting != tier else { return }
                    UsageCounting.choose(tier)
                    Task { await refreshStatus() }
                }
                Text("Counts how many people use Sevoflurane. On each day you use it, one anonymous check-in is sent:")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(
                    "\u{2022} Sevoflurane and macOS versions\n"
                        + "\u{2022} processor, chip family and memory size\n"
                        + "\u{2022} language and the date\n"
                        + "\u{2022} how many of the last 7 days you used it",
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                Text("It never includes which games or programs you run, and nothing in it names you or your account.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Crash reports adds a report when Sevoflurane itself crashes, with your name, your Mac\u{2019}s name and folder paths removed. A game\u{2019}s crash is sent only from the crash prompt. Turning this off deletes everything this Mac sent.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let line = statusLine {
                    Text(line)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Usage count")
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

/// A game's own Discord traffic, and the presence Sevoflurane publishes for
/// games Discord knows.
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
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Discord presence in games", isOn: $discordBridge)
                    .toggleStyle(.switch)
                    .disabled(!hasDiscordBridge)
                    .onChange(of: discordBridge) { _, enabled in
                        Preferences.discordBridge = enabled
                    }
                Text(InterfaceCopy.localized(hasDiscordBridge
                        ? "Games with their own Discord support show their status. Restart Steam to apply a change."
                        : "Only the built-in engine includes the Discord relay. Select it in Engine settings."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalDiscordBridge, highlighted: highlighted)
            .onAppear {
                discordBridge = Preferences.discordBridge
                discordPresence = Preferences.discordPresence
            }
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Show what you play in Discord", isOn: $discordPresence)
                    .toggleStyle(.switch)
                    .onChange(of: discordPresence) { _, enabled in
                        Preferences.discordPresence = enabled
                    }
                Text("Games in Discord's database show as what you play.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalDiscordPresence, highlighted: highlighted)
        } header: {
            Text("Discord")
        }
    }
}

// MARK: - Uninstall

/// The uninstall button and the dialog that asks whether games go too.
private struct GeneralUninstallSection: View {
    let provisioner: Provisioner
    let store: StorageStore
    /// The supervisor to stand down before the uninstall; `nil` in previews.
    let supervisor: ClientSupervisor?
    let highlighted: SettingsAnchor?
    @State private var confirmingUninstall = false

    var body: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Sevoflurane").font(.headline)
                    Text("Removes Sevoflurane and its downloaded engines and toolkits. You can choose whether to remove games.")
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
        .accessibilityLabel("Copy")
    }
}
