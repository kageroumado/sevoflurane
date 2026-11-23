import Propofol
import SwiftUI

/// Settings › Engine: the Wine underneath. Engine and bottle, thread
/// synchronization, dependencies, DLL overrides, environment variables,
/// winecfg, and Repair.
struct EngineSettings: View {
    let store: EngineStore
    let graphics: GraphicsStore
    let shaders: ShaderStore
    let compatibility: CompatibilityStore
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    /// The bottle picker's selection, seeded once the store has refreshed.
    @State private var bottleChoice = ""

    var body: some View {
        let defaults = store.bottleDefaults
        Form {
            EngineSelectionSection(
                store: store,
                provisioner: provisioner,
                highlighted: highlighted,
                bottleChoice: $bottleChoice,
            )
            if store.stagedEngine.isCrossOver {
                CrossOverNotice(engine: store.stagedEngine)
            }
            MsyncSection(graphics: graphics, crossOver: store.stagedEngine.isCrossOver, highlighted: highlighted)
            if !store.stagedEngine.isCrossOver {
                SettingSections(store: defaults, shaders: shaders, highlighted: highlighted)
                EnvironmentSection(store: defaults)
            }
            KnownFixesSection(highlighted: highlighted)
            DependenciesSection(
                store: store,
                compatibility: compatibility,
                highlighted: highlighted,
            )
            DLLOverridesSection(compatibility: compatibility, highlighted: highlighted)
            TroubleshootingSection(
                store: store,
                compatibility: compatibility,
                provisioner: provisioner,
                highlighted: highlighted,
            )
        }
        .formStyle(.grouped)
        .task {
            await store.refresh()
            bottleChoice = store.stagedBottle
            compatibility.refresh()
        }
    }
}

// MARK: - Engine & bottle

/// "Where Steam runs": the engine and bottle pickers, the feed's offer, an
/// engine from disk, and the row that applies a staged change.
private struct EngineSelectionSection: View {
    let store: EngineStore
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?
    @Binding var bottleChoice: String

    /// The bottle picker's sentinel for "type a new name".
    static let newBottleTag = "\u{0}new"

    var body: some View {
        Section {
            EnginePicker(store: store, bottleChoice: $bottleChoice)
            BottlePicker(store: store, bottleChoice: $bottleChoice)
            if bottleChoice == Self.newBottleTag {
                NewBottleField(store: store, bottleChoice: $bottleChoice)
            }
            EngineUpdateRow(store: store)
            EngineFileRow(store: store, provisioner: provisioner, bottleChoice: $bottleChoice)
            if store.hasChanges || store.isSwitching {
                EngineSwitchRow(
                    store: store,
                    provisioner: provisioner,
                    bottleChoice: $bottleChoice,
                )
            } else if let error = store.standingFailure {
                EngineStandingFailure(store: store, error: error)
            }
        } header: {
            Text("Where Steam runs")
        } footer: {
            Text("Each bottle has its own Steam installation, games, and settings.")
        }
        .highlightable(.engineSelection, highlighted: highlighted)
    }
}

/// The staged engine, with the chosen option's detail line.
private struct EnginePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        SettingsRow(caption: store.options.first { $0.engine == store.stagedEngine }?.detail ?? "") {
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
            .endsOnControlLine()
            .disabled(store.isSwitching)
        }
    }
}

/// The staged bottle: every bottle on disk, plus the new-name entry.
private struct BottlePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        SettingsRow {
            Picker("Bottle", selection: $bottleChoice) {
                ForEach(store.bottles, id: \.name) { bottle in
                    Text(bottle.hasSteam ? bottle.name : String(localized: "\(bottle.name) (no Steam yet)"))
                        .tag(bottle.name)
                }
                Text("New bottle…").tag(EngineSelectionSection.newBottleTag)
                // A staged name not on disk yet keeps its own row, so the picker
                // never shows an empty selection.
                if store.stagedBottleIsNew, !store.stagedBottle.isEmpty,
                   bottleChoice == store.stagedBottle {
                    Text("\(store.stagedBottle) (new)").tag(store.stagedBottle)
                }
            }
            .endsOnControlLine()
        }
        .disabled(store.isSwitching)
        .onChange(of: bottleChoice) { _, choice in
            guard choice != EngineSelectionSection.newBottleTag else { return }
            store.stagedBottle = choice
        }
    }
}

private struct NewBottleField: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    @State private var newBottleName = ""

    var body: some View {
        SettingsRow {
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
}

/// What the release feed has that this Mac does not, or the way back to it;
/// both buttons land on the feed's version.
private struct EngineUpdateRow: View {
    let store: EngineStore

    var body: some View {
        if let newer = store.newerEngine {
            ActionRow(
                title: "\(Engine.managedDisplayName(newer.version)) is available",
                caption: newer.notes ?? InterfaceCopy.localized("A newer Dormison than any installed here."),
            ) {
                Button("Update") { store.useDefaultEngine() }
                    .disabled(store.isSwitching)
            }
        } else if store.canResetToDefault, let label = store.defaultEngineLabel {
            ActionRow(
                title: "Default engine",
                caption: String(localized: "\(label) is what a fresh installation runs."),
            ) {
                Button("Reset") { store.useDefaultEngine() }
                    .disabled(store.isSwitching)
            }
        }
    }
}

/// Dormison from a file or folder, for a Mac the feed does not reach or a tree
/// built here. The engine is staged in the picker; Switch still decides when it
/// runs.
private struct EngineFileRow: View {
    let store: EngineStore
    let provisioner: Provisioner
    @Binding var bottleChoice: String

    @State private var isInstallingEngineFile = false
    @State private var engineFileError: String?

    var body: some View {
        ActionRow(
            title: "Engine from a file or folder",
            caption: InterfaceCopy.localized(engineFileDetail),
            isWarning: engineFileError != nil,
            help: .engineFile,
        ) {
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
            ?? "A dormison-r<N>.tar.xz you downloaded, or an engine folder you built."
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
}

/// A staged change: what Switch will do, with Cancel and Switch, or the running
/// switch's progress.
private struct EngineSwitchRow: View {
    let store: EngineStore
    let provisioner: Provisioner
    @Binding var bottleChoice: String

    var body: some View {
        if store.isSwitching {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(switchDetail)
                        .font(.callout)
                    Spacer()
                }
                // Only the engine download reports a real fraction; the other
                // stages spin.
                if let fraction = provisioner.stageFraction ?? store.engineFetchFraction {
                    ProgressView(value: fraction)
                }
            }
        } else {
            SettingsRow(caption: store.switchError ?? "", isWarning: true) {
                VStack(alignment: .leading, spacing: Theme.Space.sm) {
                    Text(switchSummary)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
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
    }

    private var switchSummary: String {
        let target = "\(store.stagedEngine.description), bottle "
            + "\u{201C}\(store.stagedBottle)\u{201D}"
        return store.stagedBottleIsNew
            ? String(localized: "Steam closes and installs in \(target). Your current bottle and games stay.")
            : String(localized: "Steam closes, prepares \(target), then reopens there.")
    }

    private var switchDetail: String {
        if case let .working(phase) = provisioner.activity {
            return phase
        }
        return store.switchPhase ?? String(localized: "Switching…")
    }
}

/// A switch that failed after applying its choice has no pending change to hang
/// the message on; it is read back from the record so it survives leaving the
/// pane.
private struct EngineStandingFailure: View {
    let store: EngineStore
    let error: String

    var body: some View {
        SettingsRow(
            caption: store.clientStartIsBlocked ? String(localized: "Steam cannot start until this is fixed.") : "",
        ) {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
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
    }
}

/// Says CrossOver manages this bottle, before someone reaches for the tools
/// below.
private struct CrossOverNotice: View {
    let engine: Engine

    var body: some View {
        Section {
            ActionRow(
                title: "\(engine.description) manages this bottle",
                caption: InterfaceCopy.localized("Its dependencies and Windows settings are CrossOver's to change."),
            ) {
                Button("Open \(engine == .crossoverPreview ? "Preview" : "CrossOver")") {
                    if let app = engine.crossoverApp {
                        NSWorkspace.shared.openApplication(at: app, configuration: .init())
                    }
                }
            }
        }
    }
}

// MARK: - Synchronization

/// The msync+ switch, a graphics selection like the renderer; under CrossOver it
/// switches CrossOver's own msync.
private struct MsyncSection: View {
    let graphics: GraphicsStore
    let crossOver: Bool
    let highlighted: SettingsAnchor?

    var body: some View {
        Section {
            ToggleRow(
                title: crossOver ? "Enhanced synchronization (msync)" : "Enhanced synchronization (msync+)",
                caption: String(localized: "Reduces synchronization overhead. Turn it off if a game freezes."),
                isOn: msyncBinding,
            )
            .highlightable(.engineMsync, highlighted: highlighted)
        } footer: {
            Text("Restart Steam to apply this setting.")
        }
    }

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
}

// MARK: - Known fixes

/// Whether a game's first launch takes the fix list's values (``FixLedger``).
private struct KnownFixesSection: View {
    let highlighted: SettingsAnchor?
    @State private var applies = Preferences.appliesKnownFixes

    var body: some View {
        Section {
            ToggleRow(
                title: "Apply known fixes automatically",
                caption: String(localized: "At a game's first launch, where the game has no setting of its own."),
                help: .knownFixes,
                isOn: $applies,
            )
            .onChange(of: applies) { _, on in Preferences.appliesKnownFixes = on }
            .highlightable(.engineKnownFixes, highlighted: highlighted)
        }
    }
}

// MARK: - Dependencies

/// "Game dependencies": what a new bottle downloads, and one row per
/// installable dependency.
private struct DependenciesSection: View {
    let store: EngineStore
    let compatibility: CompatibilityStore
    let highlighted: SettingsAnchor?

    var body: some View {
        Section {
            DownloadEverythingToggle()
            ForEach(compatibility.rows) { row in
                DependencyInstallRow(row: row, store: store, compatibility: compatibility)
            }
        } header: {
            Text("Game dependencies")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("Install a package if a game reports a missing DLL or displays blank text.")
                if let summary = compatibility.incompleteSummary {
                    Text(summary)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .highlightable(.engineDependencies, highlighted: highlighted)
    }
}

/// Whether a new bottle gets the optional dependencies with the required ones.
private struct DownloadEverythingToggle: View {
    @State private var downloadEverything = BottleDependencies.installsEverything

    var body: some View {
        ToggleRow(
            title: "Download everything",
            caption: String(localized: "A new bottle also gets the fonts and legacy runtimes."),
            isOn: $downloadEverything,
        )
        .onChange(of: downloadEverything) { _, value in
            BottleDependencies.installsEverything = value
        }
    }
}

private struct DependencyInstallRow: View {
    let row: CompatibilityStore.DependencyRow
    let store: EngineStore
    let compatibility: CompatibilityStore

    var body: some View {
        SettingsRow(caption: caption, isWarning: row.error != nil && !row.busy) {
            LabeledContent(row.dependency.name) {
                if row.busy {
                    ProgressView().controlSize(.small)
                } else if row.installed {
                    Label("Installed", systemImage: "checkmark.circle.fill")
                        .font(.callout)
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
    }

    private var caption: String {
        if row.busy { return InterfaceCopy.localized(row.phase ?? "working…") }
        return row.error ?? row.dependency.detail
    }
}

// MARK: - DLL overrides

private struct DLLOverridesSection: View {
    let compatibility: CompatibilityStore
    let highlighted: SettingsAnchor?

    var body: some View {
        Section {
            ForEach(compatibility.overrides) { override in
                DLLOverrideRow(override: override, compatibility: compatibility)
            }
            NewDLLOverrideRow(compatibility: compatibility)
            if let error = compatibility.overrideError {
                Text(error).font(.callout).foregroundStyle(.orange)
            }
        } header: {
            HStack(spacing: 6) {
                Text("DLL overrides")
                SettingHelpButton(help: SettingCopy.dllOverrides)
            }
        } footer: {
            Text("Applies to every program in this bottle starting with the next game launch. winecfg shows the same values; Settings › Games has per-game overrides.")
        }
        .highlightable(.engineOverrides, highlighted: highlighted)
    }
}

private struct DLLOverrideRow: View {
    let override: BottleDependencies.Override
    let compatibility: CompatibilityStore

    var body: some View {
        SettingsRow {
            LabeledContent {
                Text(override.mode)
            } label: {
                Text(override.dll)
                    .font(.system(.body, design: .monospaced))
            }
        } accessory: {
            Button {
                compatibility.removeOverride(override)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove the \(override.dll) override")
            .accessibilityLabel("Remove the \(override.dll) override")
        }
    }
}

private struct NewDLLOverrideRow: View {
    let compatibility: CompatibilityStore

    @State private var newOverrideDLL = ""
    @State private var newOverrideMode = BottleDependencies.overrideModes[0]
    @State private var libraries: [String] = []

    /// The load-order picker's width, which holds its longest value.
    private static let modeWidth: CGFloat = 140

    var body: some View {
        SettingsRow {
            HStack(spacing: Theme.Space.md) {
                DLLNameField(name: $newOverrideDLL, names: libraries)
                Picker("Load order", selection: $newOverrideMode) {
                    ForEach(BottleDependencies.overrideModes, id: \.self) { mode in
                        Text(mode).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: Self.modeWidth)
                Button("Add") {
                    compatibility.setOverride(dll: BuiltinLibraries.normalized(newOverrideDLL), mode: newOverrideMode)
                    newOverrideDLL = ""
                }
                .disabled(BuiltinLibraries.normalized(newOverrideDLL).isEmpty)
            }
        }
        .task { libraries = BuiltinLibraries.names() }
    }
}

// MARK: - Advanced

private struct TroubleshootingSection: View {
    let store: EngineStore
    let compatibility: CompatibilityStore
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    var body: some View {
        Section {
            WineConfigurationRow(store: store, compatibility: compatibility)
                .highlightable(.engineWinecfg, highlighted: highlighted)
            WineDiagnosticsToggle()
                .highlightable(.engineWineDiagnostics, highlighted: highlighted)
            RepairRow(provisioner: provisioner, highlighted: highlighted)
                .disabled(store.isSwitching)
        } header: {
            Text("Troubleshooting")
        } footer: {
            Text("Repair checks the engine, bottle, and Steam. Your games and saves remain. Restart Steam to apply logging changes.")
        }
    }
}

private struct WineConfigurationRow: View {
    let store: EngineStore
    let compatibility: CompatibilityStore

    var body: some View {
        ActionRow(
            title: "Wine configuration",
            caption: String(localized: "winecfg: Windows version, drives, audio and DLL overrides."),
        ) {
            Button("Open…") { compatibility.openWineConfiguration() }
                .disabled(store.isSwitching)
        }
    }
}

private struct WineDiagnosticsToggle: View {
    @State private var wineDiagnostics = WineLog.isDiagnosing

    var body: some View {
        ToggleRow(
            title: "Log every library a game loads",
            caption: String(localized: "The Wine log grows quickly while this is on."),
            help: .wineLog,
            isOn: $wineDiagnostics,
        )
        .onChange(of: wineDiagnostics) { _, enabled in
            WineLog.setDiagnosing(enabled)
        }
    }
}

/// The Repair control: the provisioner's activity and the button that re-runs
/// it. Also used by the gallery.
struct RepairRow: View {
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    var body: some View {
        SettingsRow(caption: failure ?? "", isWarning: true) {
            HStack(spacing: Theme.Space.sm) {
                activity
                Spacer()
                Button("Repair") {
                    Task(name: "Repair the installation") {
                        await provisioner.provisionAndConfigure()
                    }
                }
                .disabled(isWorking)
            }
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
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text("Repair could not finish.")
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Steam is ready.")
        case .idle:
            Text("Repair Steam")
        }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }

    private var failure: String? {
        if case let .failed(reason) = provisioner.activity { reason } else { nil }
    }
}
