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
    /// The release the feed calls stable: the engine a fresh install gets, so
    /// the default the pane measures "newer" against and the one Reset
    /// returns to. `nil` until the feed answers, and on a Mac that cannot
    /// reach it.
    private(set) var stableRelease: EngineManifest.Release?
    /// The download's progress while the pane is fetching the default engine.
    private(set) var engineFetchFraction: Double?
    /// The failure the pane keeps showing: this session's switch error, or
    /// the last provisioning pass's, which the pane is usually not open for
    /// and which a rebuild used to erase.
    private(set) var standingFailure: String?

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

    /// The managed engines on this Mac, oldest first.
    private var installedVersions: [String] {
        provisioner.detection?.managedEngineVersions ?? []
    }

    /// The default release when it is newer than every engine installed here —
    /// the pane's "a newer engine is available" line. A Mac with no managed
    /// engine at all is not told: the picker's own Dormison entry already
    /// offers to fetch one.
    var newerEngine: EngineManifest.Release? {
        guard let stableRelease, !installedVersions.isEmpty,
              UpdateSummary.isNewer(stableRelease.version, thanAll: installedVersions)
        else { return nil }
        return stableRelease
    }

    /// Whether the staged engine is something other than the default, so
    /// there is a default to go back to.
    var canResetToDefault: Bool {
        guard let stableRelease else { return false }
        return stagedEngine != .managed(version: stableRelease.version)
    }

    /// The name to say for the default engine, for the pane's Reset.
    var defaultEngineLabel: String? {
        stableRelease.map { Engine.managedDisplayName($0.version) }
    }

    /// Stages the default engine, fetching it first when this Mac does not
    /// have it. Reset and installing the newer release are the same move:
    /// both land on the version the feed calls stable. Switch still decides
    /// when it runs.
    func useDefaultEngine() {
        guard let release = stableRelease, !isSwitching else { return }
        isSwitching = true
        switchError = nil
        Task(name: "Install engine \(release.version)") { [weak self] in
            guard let self else { return }
            if !EngineInstaller.isInstalled(release) {
                switchPhase = "Downloading \(Engine.managedDisplayName(release.version))…"
                do {
                    try await EngineInstaller.install(release, progress: fetchProgress())
                } catch {
                    switchError = "\(error)"
                }
            }
            switchPhase = nil
            engineFetchFraction = nil
            isSwitching = false
            await refresh()
            guard switchError == nil else { return }
            stagedEngine = .managed(version: release.version)
        }
    }

    /// The installer reports from whatever thread its download landed on, and
    /// a progress tick is synchronous work on main — no Task semantics are
    /// wanted, so none are paid for.
    private func fetchProgress() -> @Sendable (String, Double?) -> Void {
        { [weak self] phase, fraction in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    self?.switchPhase = phase
                    self?.engineFetchFraction = fraction
                }
            }
        }
    }

    private var isLookingUpDefault = false

    /// The feed is asked until it answers, and then left alone: it is a
    /// signed fetch over the network, and the stable release does not move
    /// while Settings is open. Off to the side of ``refresh()``, which a
    /// switch awaits and which must not wait on a network that may be gone.
    private func refreshStableRelease() {
        guard !environment.isSimulation, stableRelease == nil, !isLookingUpDefault else {
            return
        }
        isLookingUpDefault = true
        Task(name: "Look up the default engine") { [weak self] in
            let release = try? await EngineManifest.fetch().stable
            guard let self else { return }
            stableRelease = release
            isLookingUpDefault = false
        }
    }

    func refresh() async {
        await provisioner.refreshDetection()
        rebuildOptions()
        if !isSwitching {
            stagedEngine = activeEngine
            stagedBottle = activeBottle
        }
        refreshBottles(resetChoice: false)
        refreshStandingFailure()
        refreshStableRelease()
    }

    /// Whether a failed pass is holding the client down — the pane's cue to
    /// offer starting it anyway.
    private(set) var clientStartIsBlocked = false

    private func refreshStandingFailure() {
        guard !environment.isSimulation else {
            standingFailure = switchError
            return
        }
        let recorded = BottleReadiness.lastProvision.flatMap {
            $0.succeeded ? nil : $0.reason
        }
        standingFailure = switchError ?? recorded
        clientStartIsBlocked = BottleReadiness.clientStartBlock != nil
    }

    /// Runs the failed pass again from wherever detection says it stopped,
    /// then starts the client if the bottle is whole.
    func retryProvisioning() {
        guard !isSwitching else { return }
        isSwitching = true
        switchError = nil
        Task(name: "Retry provisioning") { [weak self] in
            guard let self else { return }
            switchPhase = "Setting up the bottle…"
            await provisioner.retry()
            if case let .failed(reason) = provisioner.activity { switchError = reason }
            switchPhase = nil
            isSwitching = false
            await refresh()
            startClientIfAllowed()
        }
    }

    /// Starts the client over a provisioning failure, on the user's say-so.
    func startClientAnyway() {
        BottleReadiness.allowClientStart()
        refreshStandingFailure()
        environment.startClient(supervisor: supervisor)
    }

    private func startClientIfAllowed() {
        guard !clientStartIsBlocked else { return }
        environment.startClient(supervisor: supervisor)
    }

    private func rebuildOptions() {
        guard let detection = provisioner.detection else { return }
        var built: [EngineOption] = []
        if let crossover = detection.usableCrossOver {
            built.append(EngineOption(
                engine: .crossover,
                label: "CrossOver \(crossover.version)",
                detail: crossover.licensed ? "Licensed" : "Trial",
            ))
        }
        if let preview = detection.usableCrossOverPreview {
            built.append(EngineOption(
                engine: .crossoverPreview,
                label: "CrossOver Preview \(preview.version)",
                detail: "Keeps its own bottles. Adopting the stable ones is "
                    + "a switch inside Preview.",
            ))
        }
        for version in detection.managedEngineVersions.reversed() {
            built.append(EngineOption(
                engine: .managed(version: version),
                label: Engine.managedDisplayName(version),
                detail: "Sevoflurane's own Wine engine",
            ))
        }
        if detection.managedEngineVersions.isEmpty {
            // Not installed is still a choice: switching to it downloads the
            // engine first, the same stage the wizard runs.
            built.append(EngineOption(
                engine: .managed(version: ""),
                label: "Dormison",
                detail: "Sevoflurane's own Wine engine. Downloads about 230 MB when you switch.",
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
            switchError = "A bottle name cannot be empty or contain \u{201C}/\u{201D}."
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
            refreshStandingFailure()
            if clientStartIsBlocked {
                // A prefix whose Steam installer failed has no client to
                // start; starting one anyway is how the switch ended with a
                // supervised bottle that had no Steam in it.
                switchPhase = nil
                isSwitching = false
                await refresh()
                return
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
