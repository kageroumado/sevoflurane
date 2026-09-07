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
    let highlighted: String?

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
            if store.hasChanges || store.isSwitching {
                switchRow
            } else if let error = store.switchError {
                // A switch that failed after applying its choice has no
                // pending change left to hang the message on — the error
                // still has to be said.
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text("Where Steam runs")
        } footer: {
            Text("The engine is the translator that turns Windows into "
                + "something your Mac understands. The bottle is the pretend "
                + "Windows drive Steam lives on — games are installed inside "
                + "one, so a second bottle starts with an empty library.")
        }
        .highlightable(id: "engine.selection", highlighted: highlighted)
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
                where: { $0.engine == store.stagedEngine })?.detail {
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

    @ViewBuilder private var switchRow: some View {
        if store.isSwitching {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text(switchDetail)
                        .font(.callout)
                    Spacer()
                }
                // The engine download reports a real fraction; the other
                // stages spin.
                if let fraction = provisioner.stageFraction {
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
            ? "Switching to \(target) closes Steam, builds the new bottle, "
            + "downloads Steam into it — the long part, the same as first "
            + "run — and opens it there with an empty library. Your current "
            + "bottle and every game in it stay exactly as they are, and you "
            + "can switch back at any time."
            : "Switching to \(target) closes Steam, checks that bottle and "
            + "brings it up to date, then opens Steam there with the games "
            + "that bottle already has."
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
                Text("This bottle belongs to \(store.stagedEngine.description). "
                    + "For dependencies, overrides and Windows settings, its own "
                    + "interface is the safer place — it tracks what it installs.")
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
                    Text("Faster game speed (msync)")
                    Text("Recommended. Games spend a lot of time waiting on "
                        + "themselves, and this makes that waiting cheaper. If "
                        + "a game freezes before it reaches its menu, turn this "
                        + "off and start it again.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .highlightable(id: "engine.msync", highlighted: highlighted)
        } footer: {
            Text("Works on CrossOver and on Dormison. A Dormison from before "
                + "msync ignores this setting, so leaving it on there changes "
                + "nothing either way. Takes effect the next time a game starts.")
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
                    Text("Game windows")
                    Text("Off leaves windows as the game makes them. Fixed-size "
                        + "windows become resizable: a game that locks its window "
                        + "to one size gets a resizable one, and the picture "
                        + "scales to fit. Every game in a resizable window: that, "
                        + "and a game that covers the screen gets a resizable, "
                        + "movable window of its own while still believing it "
                        + "fills the screen — which is also where the upscaler "
                        + "draws.")
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
            .highlightable(id: "engine.windows", highlighted: highlighted)
            UpscalerPicker(shaders: shaders, selection: upscalerBinding)
                .highlightable(id: "engine.upscaler", highlighted: highlighted)
            FinalFilterPicker(selection: filterBinding)
                .highlightable(id: "engine.filter", highlighted: highlighted)
            mousePicker
        } footer: {
            Text("Sevoflurane's own engine only. This bottle's defaults; a game "
                + "can have its own in Games. "
                + (Engine.active.supportsEnvFiles
                    ? "Reaches a game the next time it starts."
                    : "Takes effect for games started after Steam restarts."))
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
                Text("A game aiming a camera takes the cursor and hides it. "
                    + "Linear hands it the mouse's own movement, so the same "
                    + "sweep of the hand turns the same distance however fast "
                    + "it is made; the Mac's pointer keeps its own feel "
                    + "everywhere else.")
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
        .highlightable(id: "engine.mouse", highlighted: highlighted)
    }

    // MARK: - Dependencies

    private var dependenciesSection: some View {
        Section {
            ForEach(compatibility.rows) { row in
                dependencyRow(row)
            }
        } header: {
            Text("Pieces some games are missing")
        } footer: {
            Text("Some games need a Windows component that Steam doesn't "
                + "install for them. If a game won't start, or its text comes "
                + "out as blank boxes, the fix is usually one of these. "
                + "Installing something that's already there does no harm, so "
                + "it is safe to try.")
        }
        .highlightable(id: "engine.dependencies", highlighted: highlighted)
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
                TextField("DLL name (e.g. dinput8)", text: $newOverrideDLL)
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
            Text("For following a fix you found somewhere. A DLL is one piece "
                + "of Windows, and this chooses which copy a game gets: the "
                + "real one installed in this bottle (native), the engine's "
                + "stand-in (builtin), or both in that order. Guides for "
                + "specific games name the DLL and the mode to use. Takes "
                + "effect the next time a game starts.")
        }
        .highlightable(id: "engine.overrides", highlighted: highlighted)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Windows settings")
                    Text("The engine's own control panel: which Windows "
                        + "version to pretend to be, drives, audio, and "
                        + "per-game overrides. For people who know what they "
                        + "are looking for.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open…") { compatibility.openWineConfiguration() }
                    .disabled(store.isSwitching)
            }
            .highlightable(id: "engine.winecfg", highlighted: highlighted)
            Toggle(isOn: $wineDiagnostics) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wine diagnostics log")
                    Text("Errors and exceptions from every Wine process, "
                        + "Steam's and each game's, written to "
                        + "~/Library/Logs/Sevoflurane-wine.log. Costs a little "
                        + "speed; leave it off unless something is being chased.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .onChange(of: wineDiagnostics) { _, enabled in
                WineLog.setDiagnosing(enabled)
            }
            .highlightable(id: "engine.wineDiagnostics", highlighted: highlighted)
            RepairRow(provisioner: provisioner, highlighted: highlighted)
                .disabled(store.isSwitching)
        } header: {
            Text("If Steam stops working")
        } footer: {
            Text("Repair runs first-launch setup again: whatever is still "
                + "there is left alone, and only what is missing or broken "
                + "gets reinstalled. Your games, saves and Steam account are "
                + "not touched. The diagnostics log takes effect when Steam "
                + "restarts.")
        }
    }
}

/// The Repair control: the provisioner's current activity and the button
/// that re-runs it. Lives here and in the gallery's Repair tiles.
struct RepairRow: View {
    let provisioner: Provisioner
    let highlighted: String?

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
        .highlightable(id: "engine.repair", highlighted: highlighted)
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
                Text("Repair stopped early.")
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
            Text("Nothing to do right now.")
        }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }
}
