import Propofol
import SwiftUI

/// Settings › Recovery: the actions that get a stuck installation running
/// again, gathered in one place. Steam and its menus, the background helper,
/// the bottle and its Wine underneath, and the problems people meet with
/// where each one's fix is. Every
/// action here keeps your games and saves — the destructive-looking ones stop
/// and restart Steam, and the resets touch only regenerable caches.
struct RecoverySettings: View {
    let provisioner: Provisioner
    let compatibility: CompatibilityStore
    /// Absent in the gallery, where a pane must move nothing on a real bottle.
    var supervisor: ClientSupervisor?
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    /// The resets that stop the client, so each confirms before it runs. The
    /// set is fixed, and none of them can reach saves or game files.
    enum Reset: String, CaseIterable, Identifiable {
        case forceQuitSteam
        case restartWindows
        case clearShaderCache
        case rebuildSteamEnvironment

        var id: String { rawValue }

        var title: String {
            switch self {
            case .forceQuitSteam: "Force-quit Steam?"
            case .restartWindows: "Restart Windows?"
            case .clearShaderCache: "Clear the shader cache?"
            case .rebuildSteamEnvironment: "Rebuild the Steam environment?"
            }
        }

        var message: String {
            switch self {
            case .forceQuitSteam:
                "Steam closes at once and reopens clean. A running game keeps playing."
            case .restartWindows:
                "Every Windows process in the bottle stops, Wine's server included, then "
                    + "Steam reopens. Slower than restarting Steam alone."
            case .clearShaderCache:
                "Steam stops, its shader cache is trashed, and it reopens and rebuilds "
                    + "the shaders. Your games and saves stay."
            case .rebuildSteamEnvironment:
                "Steam stops, its installer runs over the bottle again, and the client "
                    + "downloads itself fresh. Long — tens of minutes on a slow line. "
                    + "Your games and saves stay."
            }
        }

        var confirmLabel: String {
            switch self {
            case .forceQuitSteam: "Force-quit"
            case .restartWindows: "Restart Windows"
            case .clearShaderCache: "Clear cache"
            case .rebuildSteamEnvironment: "Rebuild"
            }
        }
    }

    /// A problem as the person meeting it would put it, with the error text
    /// they are likely to be looking at, and where its fix is.
    struct KnownIssue: Identifiable {
        let id: String
        let symptom: String
        /// What the game or Windows prints, when the problem has a wording.
        var example: String?
        let fix: String
    }

    /// Only problems with a fix a person can reach from Settings.
    static let knownIssues: [KnownIssue] = [
        KnownIssue(
            id: "dll-missing-runtime",
            symptom: "A game says a file is missing and will not start.",
            example: "\u{201C}VCRUNTIME140.dll was not found\u{201D} · MSVCP140.dll · "
                + "d3dx9_43.dll · XINPUT1_3.dll",
            fix: "These files come with Windows runtimes that games expect to be there. Install "
                + "Visual C++ runtime for VCRUNTIME and MSVCP, DirectX runtimes for d3dx9, xinput "
                + "and xaudio, in Settings › Engine › Game dependencies.",
        ),
        KnownIssue(
            id: "dll-own-copy",
            symptom: "A mod, a fix or a loader is installed and the game ignores it.",
            example: "ReShade · a widescreen fix · dinput8.dll · version.dll · winmm.dll · d3d9.dll",
            fix: "Wine uses its own copy of a library it knows. Add a DLL override for that file "
                + "in Settings › Games, set to Native, then built-in, so the game's copy wins.",
        ),
        KnownIssue(
            id: "d3dcompiler-missing",
            symptom: "A game shows a black screen, or stops while its shaders compile.",
            example: "d3dcompiler_47.dll · \u{201C}Failed to compile shader\u{201D}",
            fix: "Reinstall the Direct3D shader compiler above.",
        ),
        KnownIssue(
            id: "fonts-missing",
            symptom: "A launcher shows empty buttons, or text is boxes.",
            fix: "Install Core fonts, and Japanese, Chinese & Korean fonts for a game in those "
                + "languages, in Settings › Engine › Game dependencies.",
        ),
        KnownIssue(
            id: "wrong-renderer",
            symptom: "A game starts and its picture is wrong, flickers or stays black.",
            fix: "Choose another renderer for that game in Settings › Games. The (i) beside "
                + "Game renderer in Settings › Graphics says what each one is for.",
        ),
        KnownIssue(
            id: "black-intro-video",
            symptom: "A game shows a black screen where its intro video plays.",
            fix: "Update the engine in Settings › Engine. Dormison plays these videos.",
        ),
        KnownIssue(
            id: "menus-freeze-27",
            symptom: "Steam's menus freeze and the app looks stuck.",
            fix: "Cancel stuck menus above. macOS 27 can leave a menu tracking; Steam keeps "
                + "running behind it.",
        ),
        KnownIssue(
            id: "helper-wont-start",
            symptom: "The menu bar says the background helper won't start.",
            fix: "Repair the background helper above; approve it in Login Items if asked.",
        ),
    ]

    @State private var pendingReset: Reset?
    @State private var helper = HelperState.idle
    @State private var lastMenuResult: String?

    var body: some View {
        Form {
            steamSection
            helperSection
            bottleSection
            knownIssuesSection
        }
        .formStyle(.grouped)
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
        Section {
            actionRow(
                "Restart Steam",
                detail: "Closes Steam and reopens it. The first thing to try when it acts up.",
                button: "Restart", disabled: supervisor == nil,
            ) { supervisor?.restartNow() }
                .highlightable(.recoveryRestartSteam, highlighted: highlighted)
            actionRow(
                "Force-quit Steam",
                detail: "Kills Steam at once, then reopens it — for when a restart won't take.",
                button: "Force-quit", disabled: supervisor == nil,
            ) { pendingReset = .forceQuitSteam }
                .highlightable(.recoveryForceQuit, highlighted: highlighted)
            actionRow(
                "Cancel stuck menus",
                detail: menuDetail, button: "Cancel", disabled: steam == nil,
            ) {
                let open = steam?.cancelStuckMenus() ?? []
                lastMenuResult = open.isEmpty
                    ? "No menu was tracking."
                    : String(localized: "Ended: \(open.joined(separator: ", ")).")
            }
            .highlightable(.recoveryCancelMenus, highlighted: highlighted)
        } header: {
            Text("Steam")
        } footer: {
            Text("Your games and saves stay.")
        }
    }

    private var menuDetail: String {
        lastMenuResult
            ?? "Ends a frozen Steam menu. Steam's menus can hang on macOS 27."
    }

    // MARK: - Background helper

    private var helperSection: some View {
        Section {
            HStack(spacing: 10) {
                helperActivity
                Spacer()
                Button("Repair") { repairHelper() }
                    .disabled(helper.isWorking)
            }
            .highlightable(.recoveryHelper, highlighted: highlighted)
        } header: {
            Text("Background helper")
        } footer: {
            Text("The helper keeps Steam supervised even when this app is closed. Rebuilding it registers it fresh; approve it in Login Items if asked.")
        }
    }

    @ViewBuilder private var helperActivity: some View {
        switch helper {
        case .idle:
            Text("Repair the background helper")
        case .working:
            ProgressView().controlSize(.small)
            Text("Rebuilding the background helper…")
        case let .done(message):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(InterfaceCopy.localized(message))
        case let .failed(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(InterfaceCopy.localized(message))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Bottle & Wine

    private var bottleSection: some View {
        Section {
            RepairRow(provisioner: provisioner, highlighted: highlighted)
                .highlightable(.recoveryBottleRepair, highlighted: highlighted)
            shaderCompilerRow
            actionRow(
                "Restart Windows",
                detail: "Stops every Windows process in the bottle, Wine's server included, and "
                    + "starts again. For when restarting Steam has not helped.",
                button: "Restart", disabled: supervisor == nil,
            ) { pendingReset = .restartWindows }
                .highlightable(.recoveryWineRestart, highlighted: highlighted)
            actionRow(
                "Clear the shader cache",
                detail: "Trashes Steam's shader cache so it rebuilds on the next launch. "
                    + "For a black screen or a stuck loading bar. Your games and saves stay.",
                button: "Clear", disabled: supervisor == nil,
            ) { pendingReset = .clearShaderCache }
                .highlightable(.recoveryClearShaderCache, highlighted: highlighted)
            actionRow(
                "Rebuild the Steam environment",
                detail: rebuildDetail,
                button: "Rebuild…", disabled: isRebuilding,
            ) { pendingReset = .rebuildSteamEnvironment }
                .highlightable(.recoveryRebuildSteam, highlighted: highlighted)
            actionRow(
                "Wine configuration",
                detail: "Opens winecfg: Windows version, drives, audio, and DLL overrides.",
                button: "Open…",
            ) { compatibility.openWineConfiguration() }
                .highlightable(.recoveryWinecfg, highlighted: highlighted)
        } header: {
            Text("Bottle & Wine")
        } footer: {
            Text("Repair reinstalls the Windows components Steam needs and leaves your games and saves alone.")
        }
    }

    @ViewBuilder private var shaderCompilerRow: some View {
        if let row = compatibility.rows.first(where: { $0.id == "d3dcompiler" }) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reinstall the Direct3D shader compiler")
                    Text(InterfaceCopy.localized(row.busy ? (row.phase ?? "working…") : shaderCompilerDetail(row)))
                        .font(.caption)
                        .foregroundStyle(row.error == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Theme.Space.sm)
                if row.busy {
                    ProgressView().controlSize(.small)
                } else {
                    Button(row.installed ? "Reinstall" : "Install") {
                        compatibility.install(row.id)
                    }
                }
            }
            .highlightable(.recoveryShaderCompiler, highlighted: highlighted)
        }
    }

    private func shaderCompilerDetail(_ row: CompatibilityStore.DependencyRow) -> String {
        if let error = row.error { return error }
        return row.installed
            ? "Installed. Reinstall it if the doctor still reports it missing."
            : "Missing. A game that needs it will not start."
    }

    // MARK: - Known issues

    private var knownIssuesSection: some View {
        Section {
            ForEach(Self.knownIssues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(InterfaceCopy.localized(issue.symptom))
                    if let example = issue.example {
                        Text(InterfaceCopy.localized(example))
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text(InterfaceCopy.localized(issue.fix))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Common problems")
        } footer: {
            Text("For other problems, save a diagnostics archive in Settings › Diagnostics.")
        }
    }

    // MARK: - A reusable action row

    /// A titled row with a one-line description and a trailing button — the
    /// shape every action in this pane shares.
    private func actionRow(
        _ title: String, detail: String, button: String, disabled: Bool = false,
        action: @escaping () -> Void,
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(InterfaceCopy.localized(title))
                Text(InterfaceCopy.localized(detail))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(InterfaceCopy.localized(button), action: action)
                .disabled(disabled)
        }
    }

    // MARK: - Actions

    private func perform(_ reset: Reset) {
        switch reset {
        case .forceQuitSteam: supervisor?.forceQuit(.steam)
        case .restartWindows: supervisor?.restartWindowsNow()
        case .clearShaderCache: supervisor?.clearShaderCache()
        case .rebuildSteamEnvironment: rebuildSteamEnvironment()
        }
    }

    /// Reinstalls the client over the bottle it already has: the installer
    /// must not run under a live Steam, so the client is stopped first and
    /// brought back when the stages finish.
    private func rebuildSteamEnvironment() {
        Task(name: "Rebuild the Steam environment") {
            await supervisor?.stopForControl()
            await provisioner.refreshDetection()
            await provisioner.provisionAndConfigure(rebuildingSteam: true)
            supervisor?.startForControl()
        }
    }

    private var isRebuilding: Bool {
        if case .working = provisioner.activity { true } else { false }
    }

    private var rebuildDetail: String {
        if case let .working(phase) = provisioner.activity { return phase }
        if case let .failed(reason) = provisioner.activity {
            return String(localized: "The last attempt stopped: \(reason)")
        }
        return "Stops Steam and installs the client over this bottle again — for a "
            + "client whose own files are damaged and that Repair leaves alone. "
            + "Your games and saves stay."
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
    }
}
