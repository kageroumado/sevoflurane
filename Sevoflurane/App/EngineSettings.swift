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
    let compatibility: CompatibilityStore
    let provisioner: Provisioner
    let highlighted: String?

    /// The bottle picker's sentinel for "type a new name".
    private static let newBottleTag = "\u{0}new"
    @State private var bottleChoice = ""
    @State private var newBottleName = ""
    @State private var newOverrideDLL = ""
    @State private var newOverrideMode = BottleDependencies.overrideModes[0]

    var body: some View {
        Form {
            selectionSection
            if store.stagedEngine.isCrossOver {
                crossoverCard
            }
            msyncSection
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
            Text("Wine & bottle")
        } footer: {
            Text("The engine is the Wine that runs Steam; the bottle is the "
                + "Windows disk it runs in. Games live inside a bottle, so "
                + "each bottle downloads its own.")
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
            ? "Switch to \(target): Steam stops, the new bottle is created and "
            + "Steam downloads into it (the long first-run step), then Steam "
            + "starts there. Your current bottle and its games stay untouched."
            : "Switch to \(target): Steam stops, the bottle is checked and "
            + "brought up to date, then Steam starts there."
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
                    Text("Enhanced synchronization (msync)")
                    Text("Faster thread synchronization in most games. Turn off "
                        + "if a game deadlocks at launch. Takes effect the next "
                        + "time a game starts.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .highlightable(id: "engine.msync", highlighted: highlighted)
        }
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
            Text("Steam installs most of what a game declares it needs; these "
                + "cover the rest — the same set CrossOver bundles into its "
                + "Steam bottles. Installing one that's already present is "
                + "harmless.")
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
            Text("Which copy of a system DLL games get: the one installed in "
                + "the bottle (native), Wine's own (builtin), or both in "
                + "order. A game that wants a DLL Wine half-implements — a "
                + "guide will usually name it — gets it as native. Takes "
                + "effect the next time a game starts.")
        }
        .highlightable(id: "engine.overrides", highlighted: highlighted)
    }

    // MARK: - Advanced

    private var advancedSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Wine configuration")
                    Text("The engine's own settings window: Windows version, "
                        + "per-application overrides, drives, audio.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Open…") { compatibility.openWineConfiguration() }
                    .disabled(store.isSwitching)
            }
            .highlightable(id: "engine.winecfg", highlighted: highlighted)
            RepairRow(provisioner: provisioner, highlighted: highlighted)
                .disabled(store.isSwitching)
        } header: {
            Text("Advanced")
        } footer: {
            Text("Repair runs the same setup as first launch: anything present "
                + "is kept, anything missing or broken is reinstalled. Games "
                + "and saves are untouched.")
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
            Text(reason).font(.callout)
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text("Steam is ready.")
        case .idle:
            Image(systemName: "checkmark.circle")
                .foregroundStyle(.secondary)
            Text("Nothing in progress.")
        }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }
}
