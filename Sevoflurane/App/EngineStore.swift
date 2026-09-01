import Foundation

/// What the Engine pane shows and changes: which Wine runs the bottle, which
/// bottle it runs, and the switch that applies both.
///
/// Selection is staged — the pickers edit `stagedEngine`/`stagedBottle`, and
/// nothing on the machine moves until `apply()`, because a switch stops
/// Steam, may provision a whole new bottle, and restarts. The active pair is
/// always re-read from `Engine.active`/`SteamBottle.name`, so state written
/// by the CLI or the wizard shows up on refresh.
@MainActor
@Observable
final class EngineStore {
    struct EngineOption: Identifiable, Equatable {
        let engine: Engine
        let label: String
        let detail: String
        var id: String { engine.description }
    }

    private(set) var options: [EngineOption] = []
    private(set) var bottles: [SetupDetection.Bottle] = []
    var stagedEngine: Engine = .crossover {
        didSet { refreshBottles(resetChoice: oldValue != stagedEngine) }
    }
    var stagedBottle: String = SteamBottle.defaultName
    private(set) var isSwitching = false
    private(set) var switchPhase: String?
    private(set) var switchError: String?

    private let provisioner: Provisioner
    private weak var supervisor: ClientSupervisor?
    private let environment: any EngineEnvironment

    init(
        provisioner: Provisioner,
        supervisor: ClientSupervisor?,
        environment: (any EngineEnvironment)? = nil,
    ) {
        self.provisioner = provisioner
        self.supervisor = supervisor
        self.environment = environment ?? LiveEngineEnvironment()
    }

    var activeEngine: Engine { environment.activeEngine }
    var activeBottle: String { environment.activeBottle }

    /// Whether the staged pair differs from what's running.
    var hasChanges: Bool {
        stagedEngine != activeEngine || stagedBottle != activeBottle
    }

    /// Whether the staged bottle would be created from scratch.
    var stagedBottleIsNew: Bool {
        !bottles.contains { $0.name == stagedBottle }
    }

    func refresh() async {
        await provisioner.refreshDetection()
        rebuildOptions()
        if !isSwitching {
            stagedEngine = activeEngine
            stagedBottle = activeBottle
        }
        refreshBottles(resetChoice: false)
    }

    private func rebuildOptions() {
        guard let detection = provisioner.detection else { return }
        var built: [EngineOption] = []
        if let crossover = detection.usableCrossOver {
            built.append(EngineOption(
                engine: .crossover,
                label: "CrossOver \(crossover.version)",
                detail: crossover.licensed ? "licensed" : "trial",
            ))
        }
        if let preview = detection.usableCrossOverPreview {
            built.append(EngineOption(
                engine: .crossoverPreview,
                label: "CrossOver Preview \(preview.version)",
                detail: "keeps its own bottles; adopting stable ones is "
                    + "Preview's own opt-in",
            ))
        }
        for version in detection.managedEngineVersions.reversed() {
            built.append(EngineOption(
                engine: .managed(version: version),
                label: "Built-in engine \(version)",
                detail: "Sevoflurane's managed Wine",
            ))
        }
        if detection.managedEngineVersions.isEmpty {
            // Not installed is still a choice: switching to it downloads the
            // engine first, the same stage the wizard runs.
            built.append(EngineOption(
                engine: .managed(version: ""),
                label: "Built-in engine",
                detail: "downloads on switch (~230 MB)",
            ))
        }
        options = built
        // The active engine always appears, even when detection would hide
        // it (an expired trial that is nonetheless running right now).
        if !built.contains(where: { $0.engine == activeEngine }) {
            options.insert(EngineOption(
                engine: activeEngine,
                label: activeEngine.description,
                detail: "active",
            ), at: 0)
        }
    }

    private func refreshBottles(resetChoice: Bool) {
        bottles = environment.bottles(for: stagedEngine)
        guard resetChoice else { return }
        // Landing on a new engine, prefer its Steam bottle, then its first
        // bottle, then the name a fresh provision would create.
        stagedBottle = bottles.first(where: \.hasSteam)?.name
            ?? bottles.first?.name
            ?? SteamBottle.defaultName
    }

    /// The switch itself: stop Steam, persist the pair, provision whatever
    /// the new bottle is missing, start Steam again. Provisioning progress
    /// narrates through `provisioner.activity`, same as Repair.
    func apply() {
        guard hasChanges, !isSwitching else { return }
        let engine = stagedEngine
        let bottle = stagedBottle.trimmingCharacters(in: .whitespaces)
        guard !bottle.isEmpty, !bottle.contains("/") else {
            switchError = "bottle names can't be empty or contain \u{201C}/\u{201D}"
            return
        }
        isSwitching = true
        switchError = nil
        Task(name: "Switch to \(engine) / \(bottle)") { [weak self] in
            guard let self else { return }
            switchPhase = "Stopping Steam…"
            await environment.stopClient(supervisor: supervisor)
            environment.choose(engine: engine, bottle: bottle)
            EventLog.enqueue(.app, "switched to \(engine), bottle \(bottle)")
            switchPhase = "Checking the new environment…"
            await provisioner.refreshDetection()
            if provisioner.needsSetup {
                switchPhase = "Setting up the bottle…"
                await provisioner.provisionAndConfigure()
                if case let .failed(reason) = provisioner.activity {
                    // The choice stays: detection drives everything, so
                    // Repair (or Try Again here) continues from where this
                    // stopped rather than unwinding to a half-old state.
                    switchError = reason
                    // What did land still gets the idempotent bottle
                    // configuration — a half-provisioned bottle the client
                    // can finish on its own must not also run with winebus
                    // polling and no renderer staged.
                    await provisioner.configureBottle(named: bottle)
                }
            } else {
                await provisioner.configureBottle(named: bottle)
            }
            switchPhase = "Starting Steam…"
            environment.startClient(supervisor: supervisor)
            switchPhase = nil
            isSwitching = false
            await refresh()
        }
    }

    func revert() {
        guard !isSwitching else { return }
        stagedEngine = activeEngine
        stagedBottle = activeBottle
        switchError = nil
    }
}
