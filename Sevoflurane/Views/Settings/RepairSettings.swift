import SwiftUI

/// Settings › Recovery: the actions that get a stuck installation running
/// again (Steam and its menus, the background helper, the bottle and its
/// Wine), and common problems, each a way to its fix. Every action keeps
/// games and saves: the destructive-looking ones stop and restart Steam, and
/// the resets touch only regenerable caches.
struct RecoverySettings: View {
    let provisioner: Provisioner
    let compatibility: CompatibilityStore
    /// Optional so a pane can be drawn with nothing to act on; the gallery
    /// passes a preview supervisor and no `steam`.
    var supervisor: ClientSupervisor?
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    /// The resets that stop the client, so each confirms before it runs. The
    /// set is fixed, and none of them can reach saves or game files.
    enum Reset: String, CaseIterable, Identifiable {
        case forceQuitSteam
        case restartWindows
        case clearShaderCache
        case rebuildBottle

        var id: String { rawValue }

        var title: String {
            switch self {
            case .forceQuitSteam: "Force Quit Steam?"
            case .restartWindows: "Restart Windows?"
            case .clearShaderCache: "Clear the shader cache?"
            case .rebuildBottle: "Rebuild the bottle?"
            }
        }

        var message: String {
            switch self {
            case .forceQuitSteam:
                "Steam closes at once and reopens clean. A running game keeps playing."
            case .restartWindows:
                "Every Windows process in the bottle stops, Wine\u{2019}s server included, then "
                    + "Steam reopens. Slower than restarting Steam alone."
            case .clearShaderCache:
                "Steam stops, its shader cache is trashed, and it reopens and rebuilds "
                    + "the shaders. Your games and saves stay."
            case .rebuildBottle:
                "Steam stops, its installer runs over the bottle again, and the client "
                    + "downloads itself fresh. Long: tens of minutes on a slow line. "
                    + "Your games and saves stay."
            }
        }

        var confirmLabel: String {
            switch self {
            case .forceQuitSteam: "Force Quit Steam"
            case .restartWindows: "Restart Windows"
            case .clearShaderCache: "Clear Shader Cache"
            case .rebuildBottle: "Rebuild Bottle"
            }
        }
    }

    /// A problem as the person meeting it would put it, what fixes it in one
    /// line, and the row that does.
    struct KnownIssue: Identifiable {
        let id: String
        let symptom: String
        let fix: String
        let target: SettingsAnchor
    }

    /// Only problems with a fix a person can reach from Settings.
    static let knownIssues: [KnownIssue] = [
        KnownIssue(
            id: "dll-missing-runtime",
            symptom: "A game says a file is missing and will not start",
            fix: "Install the Visual C++ runtime, or the DirectX runtimes for d3dx9 and xinput.",
            target: .engineDependencies,
        ),
        KnownIssue(
            id: "dll-own-copy",
            symptom: "A mod, a fix, or a loader is installed and the game ignores it",
            fix: "Add a DLL override for its file to that game, set to Native, then built-in.",
            target: .gamesSettings,
        ),
        KnownIssue(
            id: "d3dcompiler-missing",
            symptom: "A game shows a black screen, or stops while its shaders compile",
            fix: "Install the Direct3D shader compiler again.",
            target: .recoveryShaderCompiler,
        ),
        KnownIssue(
            id: "fonts-missing",
            symptom: "A launcher shows empty buttons, or text is boxes",
            fix: "Install Core fonts; Japanese, Chinese, and Korean games need their fonts too.",
            target: .engineDependencies,
        ),
        KnownIssue(
            id: "wrong-renderer",
            symptom: "A game starts and its picture is wrong, flickers, or stays black",
            fix: "Choose another renderer for that game.",
            target: .gamesSettings,
        ),
        KnownIssue(
            id: "black-intro-video",
            symptom: "A game shows a black screen where its intro video plays",
            fix: "Update the engine. Dormison plays these videos.",
            target: .engineSelection,
        ),
        KnownIssue(
            id: "menus-freeze-27",
            symptom: "Steam\u{2019}s menus freeze and the app looks stuck",
            fix: "Dismiss the stuck menus. Steam keeps running behind a frozen menu.",
            target: .recoveryCancelMenus,
        ),
        KnownIssue(
            id: "helper-wont-start",
            symptom: "The menu bar says the background helper won\u{2019}t start",
            fix: "Repair the helper, and approve it in Login Items if asked.",
            target: .recoveryHelper,
        ),
        KnownIssue(
            id: "something-else",
            symptom: "Something else",
            fix: "Save a diagnostics archive and send it with your report.",
            target: .diagnosticsSave,
        ),
    ]

    @State private var pendingReset: Reset?
    @State private var helper = HelperState.idle
    @State private var lastMenuResult: String?

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            steamSection
            helperSection
            bottleSection
            SettingsSection(title: "Common problems") {
                ForEach(Self.knownIssues) { issue in
                    SettingsJump(
                        title: "\(InterfaceCopy.localized(issue.symptom))",
                        caption: InterfaceCopy.localized(issue.fix),
                        target: issue.target,
                    )
                }
            }
        }
        .task { compatibility.refresh() }
        .confirmationDialog(
            pendingReset.map { InterfaceCopy.localized($0.title) } ?? "", isPresented: confirmingReset,
            titleVisibility: .visible, presenting: pendingReset,
        ) { reset in
            Button(InterfaceCopy.localized(reset.confirmLabel), role: .destructive) { perform(reset) }
            Button("Cancel", role: .cancel) {}
        } message: { reset in
            Text(InterfaceCopy.localized(reset.message))
        }
    }

    private var confirmingReset: Binding<Bool> {
        Binding(get: { pendingReset != nil }, set: { if !$0 { pendingReset = nil } })
    }

    // MARK: - Steam

    private var steamSection: some View {
        SettingsSection(title: "Steam", footer: "Your games and saves stay.") {
            SettingsAction(
                title: "Steam", caption: String(localized: "The first thing to try when Steam acts up."),
            ) {
                Button("Restart Steam") { supervisor?.restartNow() }
                    .disabled(supervisor == nil)
            }
            .highlightable(.recoveryRestartSteam, highlighted: highlighted)
            SettingsAction(
                title: "Steam that won\u{2019}t restart",
                caption: String(localized: "A running game keeps playing."),
            ) {
                Button("Force Quit Steam") { pendingReset = .forceQuitSteam }
                    .disabled(supervisor == nil)
            }
            .highlightable(.recoveryForceQuit, highlighted: highlighted)
            SettingsAction(
                title: "Stuck Steam menus",
                caption: lastMenuResult ?? String(localized: "Steam\u{2019}s menus can freeze on macOS 27."),
            ) {
                Button("Dismiss Menus") {
                    let open = steam?.cancelStuckMenus() ?? []
                    lastMenuResult = open.isEmpty
                        ? String(localized: "No menu was tracking.")
                        : String(localized: "Ended: \(open.joined(separator: ", ")).")
                }
                .disabled(steam == nil)
            }
            .highlightable(.recoveryCancelMenus, highlighted: highlighted)
        }
    }

    // MARK: - Background helper

    private var helperSection: some View {
        SettingsSection(
            title: "Background helper",
            footer: "The helper keeps Steam supervised while Sevoflurane is closed.",
        ) {
            SettingsAction(
                title: "Registration", caption: helper.caption, state: helper.state, isWorking: helper.isWorking,
            ) {
                Button("Repair Helper") { repairHelper() }
                    .disabled(helper.isWorking)
            }
            .highlightable(.recoveryHelper, highlighted: highlighted)
        }
    }

    // MARK: - Bottle

    private var bottleSection: some View {
        SettingsSection(title: "Bottle", footer: "Your games and saves stay.") {
            RepairRow(provisioner: provisioner)
                .highlightable(.recoveryBottleRepair, highlighted: highlighted)
            if let row = compatibility.rows.first(where: { $0.id == "d3dcompiler" }) {
                ShaderCompilerRow(row: row) { compatibility.install(row.id) }
                    .highlightable(.recoveryShaderCompiler, highlighted: highlighted)
            }
            SettingsAction(
                title: "Windows", caption: String(localized: "For when restarting Steam has not helped."),
            ) {
                Button("Restart Windows") { pendingReset = .restartWindows }
                    .disabled(supervisor == nil)
            }
            .highlightable(.recoveryWineRestart, highlighted: highlighted)
            SettingsAction(
                title: "Shader cache", caption: String(localized: "For a black screen or a stuck loading bar."),
            ) {
                Button("Clear Shader Cache") { pendingReset = .clearShaderCache }
                    .disabled(supervisor == nil)
            }
            .highlightable(.recoveryClearShaderCache, highlighted: highlighted)
            SettingsAction(
                title: "Steam client", caption: rebuildCaption, state: rebuildState, isWorking: isRebuilding,
            ) {
                Button("Rebuild Bottle…") { pendingReset = .rebuildBottle }
                    .disabled(isRebuilding)
            }
            .highlightable(.recoveryRebuildSteam, highlighted: highlighted)
            SettingsAction(
                title: "Wine configuration",
                caption: String(localized: "winecfg: Windows version, drives, audio, and DLL overrides."),
            ) {
                Button("Open Wine Configuration") { compatibility.openWineConfiguration() }
            }
            .highlightable(.recoveryWinecfg, highlighted: highlighted)
        }
    }

    // MARK: - Actions

    private func perform(_ reset: Reset) {
        switch reset {
        case .forceQuitSteam: supervisor?.forceQuit(.steam)
        case .restartWindows: supervisor?.restartWindowsNow()
        case .clearShaderCache: supervisor?.clearShaderCache()
        case .rebuildBottle: rebuildBottle()
        }
    }

    /// Reinstalls the client over the bottle it already has: the installer
    /// must not run under a live Steam, so the client is stopped first and
    /// brought back when the stages finish.
    private func rebuildBottle() {
        Task(name: "Rebuild the bottle") {
            await supervisor?.stopForControl()
            await provisioner.refreshDetection()
            await provisioner.provisionAndConfigure(rebuildingSteam: true)
            supervisor?.startForControl()
        }
    }

    private var isRebuilding: Bool {
        if case .working = provisioner.activity { true } else { false }
    }

    private var rebuildCaption: String {
        if case let .working(phase) = provisioner.activity { return phase }
        return String(localized: "For a damaged Steam client that Repair leaves alone.")
    }

    private var rebuildState: SettingsRowState {
        guard case let .failed(reason) = provisioner.activity else { return .normal }
        return .failure(String(localized: "The last attempt stopped: \(reason)"))
    }

    private func repairHelper() {
        helper = .working
        Task(name: "Repair the background helper") {
            let result: DaemonService.RepairResult = if let supervisor {
                await supervisor.repairDaemon()
            } else {
                await DaemonService.repair()
            }
            switch result {
            case .reachable:
                helper = .done("The background helper is running.")
            case .alreadyHealthy:
                helper = .done("The background helper is already healthy.")
            case .restartedClient:
                helper = .done("The background helper had given up on Steam. Steam is restarting.")
            case let .needsApproval(message):
                helper = .failed(message)
            case let .failed(reason):
                helper = .failed(reason)
            }
        }
    }

    private enum HelperState {
        case idle
        case working
        case done(String)
        case failed(String)

        var isWorking: Bool {
            if case .working = self { true } else { false }
        }

        var caption: String {
            switch self {
            case .idle, .failed: String(localized: "Registers the helper fresh. Approve it in Login Items if asked.")
            case .working: String(localized: "Rebuilding the background helper…")
            case let .done(message): InterfaceCopy.localized(message)
            }
        }

        var state: SettingsRowState {
            if case let .failed(message) = self { .failure(InterfaceCopy.localized(message)) } else { .normal }
        }
    }
}

/// The Direct3D shader compiler: whether the bottle has it, and the button
/// that installs it again.
private struct ShaderCompilerRow: View {
    let row: CompatibilityStore.DependencyRow
    let install: () -> Void

    var body: some View {
        SettingsAction(title: "Direct3D shader compiler", caption: caption, state: state, isWorking: row.busy) {
            Button("Install Shader Compiler", action: install)
                .disabled(row.busy)
        }
    }

    private var caption: String {
        row.busy
            ? InterfaceCopy.localized(row.phase ?? "working…")
            : String(localized: "Installed. Install it again if a game still reports it missing.")
    }

    private var state: SettingsRowState {
        if row.busy { return .normal }
        if let error = row.error { return .failure(error) }
        return row.installed
            ? .normal : .warning(String(localized: "Missing. A game that needs it will not start."))
    }
}

/// Repair: the provisioner's activity and the button that runs it again.
struct RepairRow: View {
    let provisioner: Provisioner

    var body: some View {
        SettingsAction(title: "Steam installation", caption: caption, state: state, isWorking: isWorking) {
            if case .done = provisioner.activity {
                SettingsStatus(.done, String(localized: "Ready"))
            }
            Button("Repair Steam") {
                Task(name: "Repair the installation") {
                    await provisioner.provisionAndConfigure()
                }
            }
            .disabled(isWorking)
        }
        .task { await provisioner.refreshDetection() }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }

    private var caption: String {
        if case let .working(phase) = provisioner.activity { return phase }
        return String(localized: "Reinstalls the Windows components Steam needs.")
    }

    private var state: SettingsRowState {
        if case let .failed(reason) = provisioner.activity { .failure(reason) } else { .normal }
    }
}
