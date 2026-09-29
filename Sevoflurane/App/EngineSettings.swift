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

    /// The bottle picker's selection. The pane seeds it once the store has
    /// refreshed; the selection section's rows read and write it.
    @State private var bottleChoice = ""
    /// The bottle level of the settings hierarchy: every game's defaults.
    @State private var defaults = SettingsStore(scope: .bottle(SteamBottle.name))

    var body: some View {
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
            }
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

/// "Where Steam runs": the engine and bottle pickers, the release feed's
/// offer, an engine from disk, and the row that carries a staged change out.
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
            UpdateChannelRow(store: store)
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

/// The staged engine, with the chosen option's detail line under the picker.
private struct EnginePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
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
}

/// The staged bottle: every bottle on disk, plus the entry that opens the
/// new-name field.
private struct BottlePicker: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    var body: some View {
        Picker("Bottle", selection: $bottleChoice) {
            ForEach(store.bottles, id: \.name) { bottle in
                Text(bottle.hasSteam ? bottle.name : String(localized: "\(bottle.name) (no Steam yet)"))
                    .tag(bottle.name)
            }
            Text("New bottle…").tag(EngineSelectionSection.newBottleTag)
            // A staged name that isn't on disk yet keeps its own row, so the
            // picker never shows an empty selection.
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

/// The name of a bottle to create, staged with Use.
private struct NewBottleField: View {
    let store: EngineStore
    @Binding var bottleChoice: String

    @State private var newBottleName = ""

    var body: some View {
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
}

/// What the release feed has that this Mac does not, and the way back to
/// it. Both buttons do the same thing — land on the version the feed
/// names for this Mac's update channel — so the row says whichever of the
/// two is true.
private struct EngineUpdateRow: View {
    let store: EngineStore

    var body: some View {
        if let newer = store.newerEngine {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Engine.managedDisplayName(newer.version)) is available")
                    Text(newer.notes ?? InterfaceCopy.localized("A newer Dormison than any installed here."))
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
}

/// Which channel this Mac takes Sevoflurane and Dormison updates from:
/// releases, or the betas that precede them. A change reaches the app's next
/// update check, the engine's next update check and the next install; the app
/// and the engine already running stay.
private struct UpdateChannelRow: View {
    let store: EngineStore

    var body: some View {
        Picker(selection: Binding(
            get: { store.channel },
            set: { channel in
                store.channel = channel
                SilentUpdates.shared.followUpdateChannel()
            },
        )) {
            ForEach(UpdateChannel.allCases, id: \.self) { channel in
                Text(channel.label).tag(channel)
            }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Update Channel")
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(
                        store.channel == .stable && store.channelIsEmpty
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary),
                    )
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .pickerStyle(.menu)
        .disabled(store.isSwitching)
    }

    private var caption: LocalizedStringKey {
        switch store.channel {
        case .beta:
            "Betas of Sevoflurane and Dormison arrive before releases and have been run on fewer Macs."
        case .stable where store.channelIsEmpty:
            "No release is out yet. Switch to Beta to get updates."
        case .stable:
            "Releases of Sevoflurane and Dormison only."
        }
    }
}

/// Dormison from a file or a folder — the route for a Mac the release
/// feed does not reach, for adding a release by hand, or for running a
/// tree built here. The engine lands beside the installed ones and is
/// staged in the picker; Switch still decides when it runs.
private struct EngineFileRow: View {
    let store: EngineStore
    let provisioner: Provisioner
    @Binding var bottleChoice: String

    @State private var isInstallingEngineFile = false
    @State private var engineFileError: String?

    var body: some View {
        CaptionedRow(caption: InterfaceCopy.localized(engineFileDetail), isWarning: engineFileError != nil) {
            LabeledContent("Engine from a file or folder") {
                if isInstallingEngineFile {
                    ProgressView().controlSize(.small)
                }
                Button("Choose…") { installEngineFile() }
                    .disabled(isInstallingEngineFile || store.isSwitching)
            }
        }
    }

    private var engineFileDetail: String {
        if isInstallingEngineFile, case let .working(phase) = provisioner.activity {
            return phase
        }
        return engineFileError
            ?? "A dormison-b<N>.tar.xz you downloaded, or an engine folder you built. "
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
}

/// A staged change on its way out: what Switch will do with Cancel and
/// Switch under it, or the running switch's phase and progress.
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

/// A switch that failed after applying its choice has no pending change
/// left to hang the message on — the error still has to be said, and it is
/// read back from the record so leaving the pane does not lose it.
private struct EngineStandingFailure: View {
    let store: EngineStore
    let error: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(error)
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            if store.clientStartIsBlocked {
                Text("Steam cannot start until this is fixed.")
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
}

/// CrossOver knows its own bottles best — say so before someone reaches
/// for the tools below on a bottle CrossOver manages.
private struct CrossOverNotice: View {
    let engine: Engine

    var body: some View {
        Section {
            CaptionedRow(caption: InterfaceCopy.localized("Its dependencies and Windows settings are CrossOver's to change.")) {
                LabeledContent("\(engine.description) manages this bottle") {
                    Button("Open \(engine == .crossoverPreview ? "Preview" : "CrossOver")") {
                        if let app = engine.crossoverApp {
                            NSWorkspace.shared.openApplication(at: app, configuration: .init())
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Synchronization

/// The msync+ switch, a graphics selection like the renderer. Under CrossOver it
/// switches CrossOver's own msync, and says so.
private struct MsyncSection: View {
    let graphics: GraphicsStore
    let crossOver: Bool
    let highlighted: SettingsAnchor?

    var body: some View {
        Section {
            Toggle(isOn: msyncBinding) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(crossOver ? "Enhanced synchronization (msync)" : "Enhanced synchronization (msync+)")
                    Text("Reduces synchronization overhead. Turn it off if a game freezes.")
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
}

// MARK: - Dependencies

/// "Game dependencies": what a new bottle downloads, and one row per
/// dependency the current bottle can install.
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
        Toggle(isOn: $downloadEverything) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Download everything")
                Text("A new bottle gets the fonts and legacy runtimes too, not the required ones alone.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onChange(of: downloadEverything) { _, value in
            BottleDependencies.installsEverything = value
        }
    }
}

/// One dependency: its state in the bottle, and the button that installs it.
private struct DependencyInstallRow: View {
    let row: CompatibilityStore.DependencyRow
    let store: EngineStore
    let compatibility: CompatibilityStore

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.dependency.name)
                Text(InterfaceCopy.localized(row.busy ? (row.phase ?? "working…") : row.dependency.detail))
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
}

// MARK: - DLL overrides

/// "DLL overrides": the bottle's overrides, and the row that adds one.
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
                Text(error).font(.caption).foregroundStyle(.orange)
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

/// One override: the DLL, its mode, and the button that removes it.
private struct DLLOverrideRow: View {
    let override: BottleDependencies.Override
    let compatibility: CompatibilityStore

    var body: some View {
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
            .accessibilityLabel("Remove the \(override.dll) override")
        }
    }
}

/// The draft of an override: a DLL name, a mode, and Add.
private struct NewDLLOverrideRow: View {
    let compatibility: CompatibilityStore

    @State private var newOverrideDLL = ""
    @State private var newOverrideMode = BottleDependencies.overrideModes[0]
    @State private var libraries: [String] = []

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            DLLNameField(name: $newOverrideDLL, names: libraries)
            Picker("Load order", selection: $newOverrideMode) {
                ForEach(BottleDependencies.overrideModes, id: \.self) { mode in
                    Text(mode).tag(mode)
                }
            }
            .labelsHidden()
            .frame(width: 140)
            Button("Add") {
                compatibility.setOverride(dll: BuiltinLibraries.normalized(newOverrideDLL), mode: newOverrideMode)
                newOverrideDLL = ""
            }
            .disabled(BuiltinLibraries.normalized(newOverrideDLL).isEmpty)
        }
        .task { libraries = BuiltinLibraries.names() }
    }
}

// MARK: - Advanced

/// "Troubleshooting": Wine's configuration window, the verbose log, and Repair.
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

/// The way into winecfg for the current bottle.
private struct WineConfigurationRow: View {
    let store: EngineStore
    let compatibility: CompatibilityStore

    var body: some View {
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
    }
}

/// The Wine log's verbose mode: every exception and every library load.
private struct WineDiagnosticsToggle: View {
    @State private var wineDiagnostics = WineLog.isDiagnosing

    var body: some View {
        Toggle(isOn: $wineDiagnostics) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Log every library a game loads")
                Text("~/Library/Logs/Sevoflurane-wine.log always records errors. This setting also records every exception and library load, so the log grows quickly.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .toggleStyle(.switch)
        .onChange(of: wineDiagnostics) { _, enabled in
            WineLog.setDiagnosing(enabled)
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
            Text("Repair Steam")
        }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }
}
