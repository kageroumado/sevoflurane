import SwiftUI

/// Settings › Engine: the Wine underneath. Engine and bottle, thread
/// synchronization, performance defaults, environment variables, known
/// fixes, dependencies and DLL overrides.
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
        SettingsForm(highlighted: highlighted) {
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
                SettingSections(store: defaults, shaders: shaders, highlighted: highlighted, groups: [.performance])
                EnvironmentSection(store: defaults)
            }
            KnownFixesSection(highlighted: highlighted)
            DependenciesSection(
                store: store,
                compatibility: compatibility,
                highlighted: highlighted,
            )
            BottleDLLOverridesSection(compatibility: compatibility, highlighted: highlighted)
        }
        .task {
            await store.refresh()
            bottleChoice = store.stagedBottle
            compatibility.refresh()
        }
    }
}

// MARK: - Engine and bottle

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
        SettingsSection(
            title: "Where Steam runs", anchor: .engineSelection,
            footer: "Each bottle has its own Steam installation, games, and settings.",
        ) {
            EnginePicker(store: store, bottleChoice: $bottleChoice)
            BottlePicker(store: store, bottleChoice: $bottleChoice)
            if bottleChoice == Self.newBottleTag {
                NewBottleField(store: store, bottleChoice: $bottleChoice)
            }
            EngineUpdateRow(store: store)
            EngineFileRow(store: store, provisioner: provisioner, bottleChoice: $bottleChoice)
            if store.isSwitching {
                EngineSwitchProgress(store: store, provisioner: provisioner)
            } else if store.hasChanges {
                EngineSwitchRow(store: store, bottleChoice: $bottleChoice)
            } else if let error = store.standingFailure {
                EngineStandingFailure(store: store, error: error)
            }
        }
        .highlightableSection(.engineSelection, highlighted: highlighted)
    }
}

/// The staged engine, with the chosen option's detail line.
private struct EnginePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        SettingsPicker(
            title: "Engine",
            caption: store.options.first { $0.engine == store.stagedEngine }?.detail ?? "",
            selection: Binding(
                get: { store.stagedEngine.description },
                set: { id in
                    guard let option = store.options.first(where: { $0.id == id })
                    else { return }
                    store.stagedEngine = option.engine
                    bottleChoice = store.stagedBottle
                },
            ),
        ) {
            ForEach(store.options) { option in
                Text(option.label).tag(option.id)
            }
        }
        .disabled(store.isSwitching)
    }
}

/// The staged bottle: every bottle on disk, plus the new-name entry.
private struct BottlePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        SettingsPicker(title: "Bottle", selection: $bottleChoice) {
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
        SettingsField(title: "Bottle name", text: $newBottleName, onSubmit: use) {
            Button("Use Name", action: use)
                .disabled(newBottleName.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func use() {
        let name = newBottleName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        store.stagedBottle = name
        bottleChoice = name
    }
}

/// What the release feed has that this Mac does not, or the way back to it;
/// both buttons land on the feed's version.
private struct EngineUpdateRow: View {
    let store: EngineStore

    var body: some View {
        if let newer = store.newerEngine {
            SettingsAction(
                title: "\(Engine.managedDisplayName(newer.version)) is available",
                caption: newer.notes ?? String(localized: "A newer Dormison than any installed here."),
            ) {
                Button("Update Engine") { store.useDefaultEngine() }
                    .disabled(store.isSwitching)
            }
        } else if store.canResetToDefault, let label = store.defaultEngineLabel {
            SettingsAction(
                title: "Default engine",
                caption: String(localized: "\(label) is what a fresh installation runs."),
            ) {
                Button("Use Default Engine") { store.useDefaultEngine() }
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
        SettingsAction(
            title: "Engine from a file or folder",
            caption: caption,
            state: .failure(ifPresent: isInstallingEngineFile ? nil : engineFileError),
            help: .engineFile,
            isWorking: isInstallingEngineFile,
        ) {
            Button("Choose…") { installEngineFile() }
                .disabled(isInstallingEngineFile || store.isSwitching)
        }
    }

    private var caption: String {
        if isInstallingEngineFile, let phase = provisioner.phase {
            return phase
        }
        return String(localized: "A dormison-r<N>.tar.xz you downloaded, or an engine folder you built.")
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

/// A staged change: what Switch will do, with the buttons that drop it or
/// run it.
private struct EngineSwitchRow: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        SettingsAction(title: "Staged change", caption: summary, state: .failure(ifPresent: store.switchError)) {
            Button("Revert") {
                store.revert()
                bottleChoice = store.stagedBottle
            }
            Button("Switch") { store.apply() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var summary: String {
        let target = "\(store.stagedEngine.description), bottle "
            + "\u{201C}\(store.stagedBottle)\u{201D}"
        return store.stagedBottleIsNew
            ? String(localized: "Steam closes and installs in \(target). Your current bottle and games stay.")
            : String(localized: "Steam closes, prepares \(target), then reopens there.")
    }
}

/// The running switch. Only the engine download reports a real fraction; the
/// other stages spin.
private struct EngineSwitchProgress: View {
    let store: EngineStore
    let provisioner: Provisioner

    var body: some View {
        SettingsProgress(title: phase, fraction: provisioner.stageFraction ?? store.engineFetchFraction)
    }

    private var phase: String {
        provisioner.phase ?? store.switchPhase ?? String(localized: "Switching…")
    }
}

/// A switch that failed after applying its choice has no pending change to hang
/// the message on; it is read back from the record so it survives leaving the
/// pane.
private struct EngineStandingFailure: View {
    let store: EngineStore
    let error: String

    var body: some View {
        SettingsAction(
            title: store.clientStartIsBlocked ? "Steam cannot start" : "The last switch failed",
            state: .failure(error),
        ) {
            if store.clientStartIsBlocked {
                Button("Start Steam Anyway") { store.startClientAnyway() }
            }
            Button("Try Again") { store.retryProvisioning() }
                .buttonStyle(.borderedProminent)
        }
    }
}

/// Says CrossOver manages this bottle, before someone reaches for the tools
/// under it.
private struct CrossOverNotice: View {
    let engine: Engine

    var body: some View {
        SettingsSection(title: "CrossOver") {
            SettingsAction(
                title: "\(engine.description) manages this bottle",
                caption: String(localized: "Its dependencies and Windows settings are CrossOver\u{2019}s to change."),
            ) {
                Button(engine == .crossoverPreview ? "Open Preview" : "Open CrossOver") {
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
        SettingsSection(title: "Synchronization", reach: .clientRestart) {
            SettingsToggle(
                title: crossOver ? "Enhanced synchronization (msync)" : "Enhanced synchronization (msync+)",
                caption: String(localized: "Reduces synchronization overhead. Turn it off if a game freezes."),
                isOn: msyncBinding,
            )
            .highlightable(.engineMsync, highlighted: highlighted)
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
        SettingsSection(title: "Known fixes") {
            SettingsToggle(
                title: "Apply known fixes automatically",
                caption: String(localized: "At a game\u{2019}s first launch, where the game has no setting of its own."),
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
        SettingsSection(
            title: "Game dependencies", anchor: .engineDependencies,
            footer: "Install a package if a game reports a missing DLL or displays blank text.",
        ) {
            InstallEverythingToggle()
            ForEach(compatibility.rows) { row in
                DependencyInstallRow(row: row, isSwitching: store.isSwitching) {
                    compatibility.install(row.id)
                }
            }
        }
        .highlightableSection(.engineDependencies, highlighted: highlighted)
    }
}

/// Whether a new bottle gets the optional dependencies with the required ones.
private struct InstallEverythingToggle: View {
    @State private var installsEverything = BottleDependencies.installsEverything

    var body: some View {
        SettingsToggle(title: "Install every package in new bottles", isOn: $installsEverything)
            .onChange(of: installsEverything) { _, value in
                BottleDependencies.installsEverything = value
            }
    }
}

private struct DependencyInstallRow: View {
    let row: CompatibilityStore.DependencyRow
    let isSwitching: Bool
    let install: () -> Void

    var body: some View {
        SettingsAction(title: "\(row.dependency.name)", caption: caption, state: state, isWorking: row.busy) {
            if row.busy {
                EmptyView()
            } else if row.installed {
                SettingsStatus(.done, String(localized: "Installed"))
            } else {
                Button("Install (\(row.dependency.download))", action: install)
                    .disabled(isSwitching)
            }
        }
    }

    private var caption: String {
        row.busy ? InterfaceCopy.localized(row.phase ?? "working…") : row.dependency.detail
    }

    /// A failed install says why; a required package the bottle lacks says so
    /// on its own row.
    private var state: SettingsRowState {
        if row.busy { return .normal }
        if let error = row.error { return .failure(error) }
        guard row.dependency.required, !row.installed else { return .normal }
        return .warning(String(localized: "Required. \(row.dependency.detail)"))
    }
}
