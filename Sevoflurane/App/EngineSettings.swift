import Propofol
import SwiftUI

/// Settings › Engine: everything about the Wine underneath — which engine
/// runs the bottle, which bottle, thread synchronization, the dependencies
/// games commonly miss, DLL overrides, Wine's own configuration window, and
/// Repair. One pane, because these knobs all answer the same question: "what
/// is the Windows machine my games run on?"
struct EngineSettings: View {
    let store: EngineStore
    let graphics: GraphicsStore
    let shaders: ShaderStore
    let compatibility: CompatibilityStore
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    /// The bottle picker's sentinel for "type a new name".
    private static let newBottleTag = "\u{0}new"
    @State private var bottleChoice = ""
    @State private var newBottleName = ""
    @State private var newOverrideDLL = ""
    @State private var newOverrideMode = BottleDependencies.overrideModes[0]
    @State private var windowTreatment = GameConfig.windows(bottle: SteamBottle.name).value
    @State private var upscaler: String? = GameConfig.upscaler(bottle: SteamBottle.name).value
    @State private var finalFilter: FinalFilter? = GameConfig.filter(bottle: SteamBottle.name).value
    @State private var mouseCurve = GameConfig.mouse(bottle: SteamBottle.name).value
    @State private var wineDiagnostics = WineLog.isDiagnosing
    @State private var isInstallingEngineFile = false
    @State private var engineFileError: String?

    var body: some View {
        Form {
            selectionSection
            if store.stagedEngine.isCrossOver {
                crossoverCard
            }
            msyncSection
            if !store.stagedEngine.isCrossOver {
                windowsSection
            }
            dependenciesSection
            overridesSection
            advancedSection
        }
        .formStyle(.grouped)
        .task {
            await store.refresh()
            bottleChoice = store.stagedBottle
            compatibility.refresh()
        }
    }

    // MARK: - Engine & bottle

    private var selectionSection: some View {
        Section {
            enginePicker
            bottlePicker
            if bottleChoice == Self.newBottleTag {
                newBottleField
            }
            engineUpdateRow
            engineFileRow
            if store.hasChanges || store.isSwitching {
                switchRow
            } else if let error = store.standingFailure {
                // A switch that failed after applying its choice has no
                // pending change left to hang the message on — the error
                // still has to be said, and it is read back from the record
                // so leaving the pane does not lose it.
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    if store.clientStartIsBlocked {
                        Text("Steam stays down until this is fixed.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    HStack {
                        Spacer()
                        if store.clientStartIsBlocked {
                            Button("Start Steam Anyway") { store.startClientAnyway() }
                        }
                        Button("Try Again") { store.retryProvisioning() }
                            .buttonStyle(.borderedProminent)
                    }
                }
            }
        } header: {
            Text("Where Steam runs")
        } footer: {
            Text("Each bottle has its own Steam installation, games, and settings.")
        }
        .highlightable(.engineSelection, highlighted: highlighted)
    }

    private var enginePicker: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker("Engine", selection: Binding(
                get: { store.stagedEngine.description },
                set: { id in
                    guard let option = store.options.first(where: { $0.id == id })
                    else { return }
                    store.stagedEngine = option.engine
                    bottleChoice = store.stagedBottle
                },
            )) {
                ForEach(store.options) { option in
                    Text(option.label).tag(option.id)
                }
            }
            .disabled(store.isSwitching)
            if let detail = store.options.first(
                where: { $0.engine == store.stagedEngine },
            )?.detail {
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var bottlePicker: some View {
        Picker("Bottle", selection: $bottleChoice) {
            ForEach(store.bottles, id: \.name) { bottle in
                Text(bottle.hasSteam ? bottle.name : "\(bottle.name) (no Steam yet)")
                    .tag(bottle.name)
            }
            Text("New bottle…").tag(Self.newBottleTag)
            // A staged name that isn't on disk yet keeps its own row, so the
            // picker never shows an empty selection.
            if store.stagedBottleIsNew, !store.stagedBottle.isEmpty,
               bottleChoice == store.stagedBottle {
                Text("\(store.stagedBottle) (new)").tag(store.stagedBottle)
            }
        }
        .disabled(store.isSwitching)
        .onChange(of: bottleChoice) { _, choice in
            guard choice != Self.newBottleTag else { return }
            store.stagedBottle = choice
        }
    }

    private var newBottleField: some View {
        HStack {
            TextField("Bottle name", text: $newBottleName)
                .textFieldStyle(.roundedBorder)
            Button("Use") {
                let name = newBottleName.trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty else { return }
                store.stagedBottle = name
                bottleChoice = name
            }
            .disabled(newBottleName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// What the release feed has that this Mac does not, and the way back to
    /// it. Both buttons do the same thing — land on the version the feed
    /// calls stable — so the row says whichever of the two is true.
    @ViewBuilder private var engineUpdateRow: some View {
        if let newer = store.newerEngine {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Engine.managedDisplayName(newer.version)) is available")
                    Text(newer.notes ?? "A newer Dormison than any installed here.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Update") { store.useDefaultEngine() }
                    .disabled(store.isSwitching)
            }
        } else if store.canResetToDefault, let label = store.defaultEngineLabel {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Default engine")
                    Text("\(label) is what a fresh installation runs.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Reset") { store.useDefaultEngine() }
                    .disabled(store.isSwitching)
            }
        }
    }

    /// Dormison from a file or a folder — the route for a Mac the release
    /// feed does not reach, for adding a release by hand, or for running a
    /// tree built here. The engine lands beside the installed ones and is
    /// staged in the picker; Switch still decides when it runs.
    private var engineFileRow: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Engine from a file or folder")
                Text(engineFileDetail)
                    .font(.callout)
                    .foregroundStyle(engineFileError == nil ? Color.secondary : Color.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if isInstallingEngineFile {
                ProgressView().controlSize(.small)
            }
            Button("Choose…") { installEngineFile() }
                .disabled(isInstallingEngineFile || store.isSwitching)
        }
    }

    private var engineFileDetail: String {
        if isInstallingEngineFile, case let .working(phase) = provisioner.activity {
            return phase
        }
        return engineFileError
            ?? "A dormison-r<N>.tar.xz you downloaded, or an engine folder you built. "
            + "Sevoflurane checks the .sig beside a tarball."
    }

    private func installEngineFile() {
        guard let source = EngineFilePanel.choose() else { return }
        isInstallingEngineFile = true
        engineFileError = nil
        Task(name: "Install engine from disk") {
            do {
                let version = try await provisioner.installEngine(from: source)
                await store.refresh()
                store.stagedEngine = .managed(version: version)
                bottleChoice = store.stagedBottle
            } catch {
                engineFileError = "\(error)"
            }
            isInstallingEngineFile = false
        }
    }

    @ViewBuilder private var switchRow: some View {
        if store.isSwitching {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(switchDetail)
                        .font(.callout)
                    Spacer()
                }
                // The engine download reports a real fraction, whether the
                // provisioner or the pane's own Update started it; the other
                // stages spin.
                if let fraction = provisioner.stageFraction ?? store.engineFetchFraction {
                    ProgressView(value: fraction)
                }
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                Text(switchSummary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = store.switchError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
                HStack {
                    Spacer()
                    Button("Cancel") {
                        store.revert()
                        bottleChoice = store.stagedBottle
                    }
                    Button("Switch") { store.apply() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
    }

    private var switchSummary: String {
        let target = "\(store.stagedEngine.description), bottle "
            + "\u{201C}\(store.stagedBottle)\u{201D}"
        return store.stagedBottleIsNew
            ? "Steam closes and installs in \(target). Your current bottle and games stay."
            : "Steam closes, prepares \(target), then reopens there."
    }

    private var switchDetail: String {
        if case let .working(phase) = provisioner.activity {
            return phase
        }
        return store.switchPhase ?? "Switching…"
    }

    /// CrossOver knows its own bottles best — say so before someone reaches
    /// for the tools below on a bottle CrossOver manages.
    private var crossoverCard: some View {
        Section {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "info.circle")
                    .font(.system(size: 18))
                    .foregroundStyle(.secondary)
                Text("\(store.stagedEngine.description) manages this bottle's dependencies and Windows settings too.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Open \(store.stagedEngine == .crossoverPreview ? "Preview" : "CrossOver")") {
                    if let app = store.stagedEngine.crossoverApp {
                        NSWorkspace.shared.openApplication(
                            at: app, configuration: .init(),
                        )
                    }
                }
            }
        }
    }

    // MARK: - Synchronization

    /// Edits go through the store, which decides whether they reach a bottle.
    private var msyncBinding: Binding<Bool> {
        Binding(
            get: { graphics.selection.msync },
            set: { enabled in
                var selection = graphics.selection
                selection.msync = enabled
                graphics.update(selection)
            },
        )
    }

    private var msyncSection: some View {
        Section {
            Toggle(isOn: msyncBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Enhanced synchronization (msync)")
                    Text("Cuts synchronization overhead. Turn it off if a game freezes.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .highlightable(.engineMsync, highlighted: highlighted)
        } footer: {
            Text("Restart Steam to apply this setting.")
        }
    }

    // MARK: - Windows

    private var windowsSection: some View {
        Section {
            Picker(selection: $windowTreatment) {
                ForEach(WindowTreatment.allCases, id: \.self) { treatment in
                    Text(treatment.label).tag(treatment)
                }
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make game windows resizable")
                    Text("A resizable window scales the picture to fit. The game "
                        + "keeps drawing at its own size.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: windowTreatment) { _, treatment in
                GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) {
                    $0.windows = treatment
                }
            }
            .highlightable(.engineWindows, highlighted: highlighted)
            UpscalerPicker(shaders: shaders, selection: upscalerBinding)
                .highlightable(.engineUpscaler, highlighted: highlighted)
            FinalFilterPicker(selection: filterBinding)
                .highlightable(.engineFilter, highlighted: highlighted)
            mousePicker
        } footer: {
            Text(Engine.active.supportsEnvFiles
                ? "Defaults for Dormison games. Change one game in Games. A change applies at the next launch."
                : "Defaults for Dormison games. Change one game in Games. Restart Steam to apply a change.")
        }
    }

    /// The bottle level has no inherit entry, so a `nil` from the picker
    /// cannot happen; a value is written when it differs from the one shown.
    private var upscalerBinding: Binding<String?> {
        Binding(
            get: { upscaler },
            set: { value in
                guard let value, value != upscaler else { return }
                upscaler = value
                GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) {
                    $0.upscaler = value
                }
            },
        )
    }

    private var filterBinding: Binding<FinalFilter?> {
        Binding(
            get: { finalFilter },
            set: { value in
                guard let value, value != finalFilter else { return }
                finalFilter = value
                GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) {
                    $0.filter = value
                }
            },
        )
    }

    private var mousePicker: some View {
        Picker(selection: $mouseCurve) {
            ForEach(MouseCurve.allCases, id: \.self) { curve in
                Text(curve.label).tag(curve)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Mouse")
                Text("Linear removes acceleration while a game controls the mouse.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: mouseCurve) { _, curve in
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) {
                $0.mouse = curve
            }
        }
        .highlightable(.engineMouse, highlighted: highlighted)
    }

    // MARK: - Dependencies

    private var dependenciesSection: some View {
        Section {
            ForEach(compatibility.rows) { row in
                dependencyRow(row)
            }
        } header: {
            Text("Game dependencies")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install one when a game reports a missing DLL or blank text.")
                if let summary = compatibility.incompleteSummary {
                    Text(summary)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .highlightable(.engineDependencies, highlighted: highlighted)
    }

    private func dependencyRow(_ row: CompatibilityStore.DependencyRow) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.dependency.name)
                Text(row.busy ? (row.phase ?? "working…") : row.dependency.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = row.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Space.sm)
            if row.busy {
                ProgressView().controlSize(.small)
            } else if row.installed {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
                    .labelStyle(.titleAndIcon)
            } else {
                Button("Install \(row.dependency.download)") {
                    compatibility.install(row.id)
                }
                .disabled(store.isSwitching)
            }
        }
    }

    // MARK: - DLL overrides

    private var overridesSection: some View {
        Section {
            ForEach(compatibility.overrides) { override in
                HStack(spacing: Theme.Space.md) {
                    Text(override.dll)
                        .font(.system(.body, design: .monospaced))
                    Spacer()
                    Text(override.mode)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button {
                        compatibility.removeOverride(override)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove the \(override.dll) override")
                }
            }
            HStack(spacing: Theme.Space.md) {
                TextField("DLL name, like dinput8", text: $newOverrideDLL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Picker("", selection: $newOverrideMode) {
                    ForEach(BottleDependencies.overrideModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 140)
                Button("Add") {
                    compatibility.setOverride(dll: newOverrideDLL, mode: newOverrideMode)
                    newOverrideDLL = ""
                }
                .disabled(newOverrideDLL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let error = compatibility.overrideError {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("DLL overrides")
        } footer: {
            Text("Choose native for the installed Windows DLL, or builtin for Wine's own. A change applies at the next game launch.")
        }
        .highlightable(.engineOverrides, highlighted: highlighted)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Windows settings")
                    Text("Windows version, drives, audio, and game overrides.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open…") { compatibility.openWineConfiguration() }
                    .disabled(store.isSwitching)
            }
            .highlightable(.engineWinecfg, highlighted: highlighted)
            Toggle(isOn: $wineDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Log every library a game loads")
                    Text("~/Library/Logs/Sevoflurane-wine.log always records errors. This adds every exception and every library load. The log then grows fast.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: wineDiagnostics) { _, enabled in
                WineLog.setDiagnosing(enabled)
            }
            .highlightable(.engineWineDiagnostics, highlighted: highlighted)
            RepairRow(provisioner: provisioner, highlighted: highlighted)
                .disabled(store.isSwitching)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Repair checks the engine, the bottle, and Steam. Your games and saves stay. Restart Steam to apply a logging change.")
        }
    }
}

/// The Repair control: the provisioner's current activity and the button
/// that re-runs it. Lives here and in the gallery's Repair tiles.
struct RepairRow: View {
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    var body: some View {
        HStack(spacing: 10) {
            activity
            Spacer()
            Button("Repair") {
                Task(name: "Repair the installation") {
                    await provisioner.provisionAndConfigure()
                }
            }
            .disabled(isWorking)
        }
        .highlightable(.engineRepair, highlighted: highlighted)
        .task { await provisioner.refreshDetection() }
    }

    @ViewBuilder
    private var activity: some View {
        switch provisioner.activity {
        case let .working(phase):
            ProgressView().controlSize(.small)
            Text(phase)
        case let .failed(reason):
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Repair could not finish.")
                Text(reason)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Steam is ready.")
        case .idle:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("Repair Steam")
        }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }
}
