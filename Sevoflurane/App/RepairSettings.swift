import Propofol
import SwiftUI

/// Settings › Recovery: the actions that get a stuck installation running
/// again, gathered in one place. Steam and its menus, the background helper,
/// the bottle and its Wine underneath, diagnostics, and a short list of the
/// problems this project has seen with the one-tap fix beside each. Every
/// action here keeps your games and saves — the destructive-looking ones stop
/// and restart Steam, and the resets touch only regenerable caches.
struct RecoverySettings: View {
    let provisioner: Provisioner
    var compatibility = CompatibilityStore()
    /// Absent in the gallery, where a pane must move nothing on a real bottle.
    var supervisor: ClientSupervisor?
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    /// Opens the report window. Absent in the gallery, where no window opens.
    var showReports: (() -> Void)?

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
                "The whole fake Windows shuts down to a fresh Wine server, then Steam "
                    + "reopens. Slower than restarting Steam alone."
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

    /// A problem this project has diagnosed, in plain language, with what to do.
    struct KnownIssue: Identifiable {
        let id: String
        let symptom: String
        let fix: String
    }

    /// Kept short and current: only what has actually been seen and has a fix
    /// a person can act on from here or from Settings › Engine.
    static let knownIssues: [KnownIssue] = [
        KnownIssue(
            id: "helper-wont-start",
            symptom: "The menu bar says the background helper won't start.",
            fix: "Repair the background helper above; approve it in Login Items if asked.",
        ),
        KnownIssue(
            id: "menus-freeze-27",
            symptom: "Steam's menus freeze and the app looks stuck (macOS 27 beta).",
            fix: "Cancel stuck menus above. This is a system beta issue, not Steam's.",
        ),
        KnownIssue(
            id: "black-intro-video",
            symptom: "A game shows a black screen on its intro video.",
            fix: "Install engine r7 or later in Settings › Engine.",
        ),
        KnownIssue(
            id: "d3dcompiler-missing",
            symptom: "A game won't start and the doctor says the Direct3D shader compiler is missing.",
            fix: "Reinstall the Direct3D shader compiler above.",
        ),
    ]

    @State private var pendingReset: Reset?
    @State private var helper = HelperState.idle
    @State private var savingDiagnostics = false
    @State private var diagnosticsError: String?
    @State private var lastMenuResult: String?

    var body: some View {
        Form {
            steamSection
            helperSection
            bottleSection
            diagnosticsSection
            knownIssuesSection
        }
        .formStyle(.grouped)
        .task { compatibility.refresh() }
        .confirmationDialog(
            pendingReset?.title ?? "", isPresented: confirmingReset,
            titleVisibility: .visible, presenting: pendingReset,
        ) { reset in
            Button(reset.confirmLabel, role: .destructive) { perform(reset) }
            Button("Cancel", role: .cancel) {}
        } message: { reset in
            Text(reset.message)
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
                    : "Ended: \(open.joined(separator: ", "))."
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
            Text("The helper keeps Steam supervised even when this app is closed. "
                + "Rebuilding it registers it fresh; approve it in Login Items if asked.")
        }
    }

    @ViewBuilder private var helperActivity: some View {
        switch helper {
        case .idle:
            Image(systemName: "arrow.clockwise.circle")
                .foregroundStyle(.secondary)
            Text("Repair the background helper")
        case .working:
            ProgressView().controlSize(.small)
            Text("Rebuilding the background helper…")
        case let .done(message):
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
        case let .failed(message):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
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
                detail: "Brings the whole fake Windows down — Wine server included — and "
                    + "starts it fresh. Try this when restarting Steam hasn't helped.",
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
            Text("Repair reinstalls the Windows components Steam needs and leaves your "
                + "games and saves alone. A full bottle reset is not offered here.")
        }
    }

    @ViewBuilder private var shaderCompilerRow: some View {
        if let row = compatibility.rows.first(where: { $0.id == "d3dcompiler" }) {
            HStack(alignment: .center, spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Reinstall the Direct3D shader compiler")
                    Text(row.busy ? (row.phase ?? "working…") : shaderCompilerDetail(row))
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
            : "Missing — a game that needs it won't start."
    }

    // MARK: - Diagnostics

    private var diagnosticsSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Save Diagnostics…")
                    Text("Writes logs, system details, and recent crashes to a ZIP on your "
                        + "Desktop. Read it before sharing.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let diagnosticsError {
                        Text(diagnosticsError).font(.caption).foregroundStyle(.orange)
                    }
                }
                Spacer()
                Button(savingDiagnostics ? "Saving…" : "Save…") { saveDiagnostics() }
                    .disabled(savingDiagnostics)
            }
            .highlightable(.recoveryDiagnostics, highlighted: highlighted)
            if let showReports {
                actionRow(
                    "Reports",
                    detail: "Every game you have run, what it left behind, and the two ways "
                        + "to share one: a zip on the Desktop, or an issue already filled in.",
                    button: "Open…",
                ) { showReports() }
                    .highlightable(.recoveryReports, highlighted: highlighted)
            }
            Toggle(isOn: debugModeBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Debug mode")
                    Text("Records far more to the logs — every library a game loads, the "
                        + "renderer, and the engine. Turn it on before reproducing a bug.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .highlightable(.recoveryDebugMode, highlighted: highlighted)
        } header: {
            Text("Diagnostics")
        } footer: {
            Text("Restart Steam to apply a debug-mode change to games. Debug mode also "
                + "lives in the menu bar popover.")
        }
    }

    private var debugModeBinding: Binding<Bool> {
        Binding(
            get: { DebugModeSwitch.shared.isOn },
            set: { DebugModeSwitch.shared.set($0) },
        )
    }

    // MARK: - Known issues

    private var knownIssuesSection: some View {
        Section {
            ForEach(Self.knownIssues) { issue in
                VStack(alignment: .leading, spacing: 2) {
                    Text(issue.symptom)
                    Text(issue.fix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Known issues")
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
                Text(title)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Button(button, action: action)
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
            return "The last attempt stopped: \(reason)"
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
            case let .needsApproval(message):
                helper = .failed(message)
            case let .failed(reason):
                helper = .failed(reason)
            }
        }
    }

    /// The `sevo` helper inside this bundle. The report is written by the
    /// same binary the terminal runs, so a zip saved from here and one from a
    /// hand-run `sevo diag` are the same report.
    static var diagnosticsHelper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
    }

    /// The bundled CLI writes the zip (`sevo diag`), so the app and the
    /// terminal produce the same report; Finder then shows it.
    private func saveDiagnostics() {
        savingDiagnostics = true
        diagnosticsError = nil
        Task(name: "Save diagnostics") {
            let result = await Subprocess.run(
                Self.diagnosticsHelper.path, ["diag", "--steam-logs"],
                capture: .combined, timeout: .seconds(90),
            )
            savingDiagnostics = false
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            guard result.status == 0, path.hasSuffix(".zip") else {
                diagnosticsError = "Could not write the report: \(result.output.suffix(200))"
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
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
