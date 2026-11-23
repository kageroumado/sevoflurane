import Foundation

/// What the Engine pane shows and changes: which Wine runs the bottle, which
/// bottle, and the switch that applies both.
///
/// The pickers edit `stagedEngine`/`stagedBottle`, and nothing moves until
/// `apply()`, because a switch stops Steam, may provision a bottle, and
/// restarts. The active pair is re-read from
/// `Engine.active`/`SteamBottle.name`, so the CLI's or wizard's changes show on
/// refresh.
@MainActor
@Observable
final class EngineStore {
    struct EngineOption: Identifiable, Equatable {
        let engine: Engine
        let label: String
        let detail: String
        var id: String { engine.description }

        init(engine: Engine, label: String, detail: String) {
            self.engine = engine
            self.label = InterfaceCopy.localized(label)
            self.detail = InterfaceCopy.localized(detail)
        }
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
    /// The release the feed offers, which a fresh install gets: what "newer" is
    /// measured against and what Reset returns to. `nil` until the feed answers
    /// or when it names no engine.
    private(set) var defaultRelease: EngineManifest.Release?
    /// The download's progress while the pane fetches the default engine.
    private(set) var engineFetchFraction: Double?
    /// The failure the pane keeps showing: this session's switch error, or the
    /// last provisioning pass's.
    private(set) var standingFailure: String?

    /// The active bottle's level of the settings hierarchy: every game's
    /// defaults. Made again when the active bottle changes.
    private(set) var bottleDefaults: SettingsStore

    private let provisioner: Provisioner
    private weak var supervisor: ClientSupervisor?
    private let environment: any EngineEnvironment

    init(
        provisioner: Provisioner,
        supervisor: ClientSupervisor?,
        environment: (any EngineEnvironment)? = nil,
    ) {
        let environment = environment ?? LiveEngineEnvironment()
        self.provisioner = provisioner
        self.supervisor = supervisor
        self.environment = environment
        bottleDefaults = SettingsStore(scope: .bottle(environment.activeBottle))
    }

    /// Points ``bottleDefaults`` at the active bottle.
    private func followActiveBottle() {
        guard bottleDefaults.scope.bottle != activeBottle else { return }
        bottleDefaults = SettingsStore(scope: .bottle(activeBottle))
    }

    var activeEngine: Engine { environment.activeEngine }
    var activeBottle: String { environment.activeBottle }

    /// Whether the staged pair differs from what's running.
    var hasChanges: Bool {
        stagedEngine != activeEngine || stagedBottle != activeBottle
    }

    #if DEBUG
        /// Puts the store where the gallery draws it: a switch under way, or
        /// one that failed and stands.
        func stage(switching phase: String?, fraction: Double? = nil, failure: String? = nil, blocksClient: Bool = false) {
            isSwitching = phase != nil
            switchPhase = phase
            engineFetchFraction = fraction
            switchError = failure
            standingFailure = failure
            clientStartIsBlocked = blocksClient
        }
    #endif

    /// Whether the staged bottle would be created from scratch.
    var stagedBottleIsNew: Bool {
        !bottles.contains { $0.name == stagedBottle }
    }

    private var installedVersions: [String] {
        provisioner.detection?.managedEngineVersions ?? []
    }

    /// The default release when it is newer than every installed engine. A Mac
    /// with no managed engine is not told: the picker's Dormison entry already
    /// offers one.
    var newerEngine: EngineManifest.Release? {
        guard let defaultRelease, !installedVersions.isEmpty,
              UpdateSummary.isNewerEngine(defaultRelease.version, thanAll: installedVersions)
        else { return nil }
        return defaultRelease
    }

    /// Whether the staged engine differs from the default.
    var canResetToDefault: Bool {
        guard let defaultRelease else { return false }
        return stagedEngine != .managed(version: defaultRelease.version)
    }

    /// The default engine's name, for the pane's Reset.
    var defaultEngineLabel: String? {
        defaultRelease.map { Engine.managedDisplayName($0.version) }
    }

    /// Stages the default engine, fetching it first when missing; Reset and
    /// Update both land here. Switch still decides when it runs.
    func useDefaultEngine() {
        guard let release = defaultRelease, !isSwitching else { return }
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

    /// The installer reports from any thread; a plain main-queue hop is enough
    /// for a progress tick.
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

    /// Asks the feed until it names a release, then stops: the release does not
    /// move while Settings is open. Kept out of ``refresh()``, which a switch
    /// awaits and which must not wait on the network.
    private func refreshDefaultRelease() {
        guard !environment.isSimulation, defaultRelease == nil, !isLookingUpDefault else { return }
        isLookingUpDefault = true
        Task(name: "Look up the default engine") { [weak self] in
            let release = try? await EngineManifest.fetch().release()
            guard let self else { return }
            defaultRelease = release
            isLookingUpDefault = false
        }
    }

    func refresh() async {
        followActiveBottle()
        await provisioner.refreshDetection()
        rebuildOptions()
        if !isSwitching {
            stagedEngine = activeEngine
            stagedBottle = activeBottle
        }
        refreshBottles(resetChoice: false)
        refreshStandingFailure()
        refreshDefaultRelease()
    }

    /// Whether a failed pass is holding the client down, so the pane offers
    /// starting it anyway.
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

    /// Re-runs the failed pass from where detection says it stopped, then
    /// starts the client if the bottle is whole.
    func retryProvisioning() {
        guard !isSwitching else { return }
        isSwitching = true
        switchError = nil
        Task(name: "Retry provisioning") { [weak self] in
            guard let self else { return }
            switchPhase = InterfaceCopy.localized("Setting up the bottle…")
            await provisioner.retry()
            if case let .failed(reason) = provisioner.activity { switchError = reason }
            switchPhase = nil
            isSwitching = false
            await refresh()
            startClientIfAllowed()
        }
    }

    /// Starts the client over a provisioning failure, at the user's say-so.
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
                label: crossover.label,
                detail: String(
                    localized: "\(crossover.licenseWord) Resizable windows, upscaling and a Dock icon per game need Dormison.",
                ),
            ))
        }
        if let preview = detection.usableCrossOverPreview {
            built.append(EngineOption(
                engine: .crossoverPreview,
                label: String(localized: "CrossOver Preview \(preview.version)"),
                detail: "Keeps its own bottles. Adopting the stable ones is "
                    + "a switch inside Preview.",
            ))
        }
        for version in detection.managedEngineVersions.reversed() {
            built.append(EngineOption(
                engine: .managed(version: version),
                label: Engine.managedDisplayName(version),
                detail: "Sevoflurane’s own Wine engine.",
            ))
        }
        if detection.managedEngineVersions.isEmpty {
            // Not installed is still a choice: switching to it downloads the
            // engine first.
            built.append(EngineOption(
                engine: .managed(version: ""),
                label: "Dormison",
                detail: "Sevoflurane’s own Wine engine. Downloads about 230 MB when you switch.",
            ))
        }
        options = built
        // The active engine always appears, even when detection would hide it
        // (an expired trial still running).
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
        // On a new engine, prefer its Steam bottle, then its first bottle, then
        // the default name.
        stagedBottle = bottles.first(where: \.hasSteam)?.name
            ?? bottles.first?.name
            ?? SteamBottle.defaultName
    }

    /// The switch: stop Steam, persist the pair, provision what the bottle
    /// lacks, start Steam. Progress narrates through `provisioner.activity`.
    func apply() {
        guard hasChanges, !isSwitching else { return }
        let engine = stagedEngine
        let bottle = stagedBottle.trimmingCharacters(in: .whitespaces)
        guard !bottle.isEmpty, !bottle.contains("/") else {
            switchError = InterfaceCopy.localized("A bottle name cannot be empty or contain \u{201C}/\u{201D}.")
            return
        }
        isSwitching = true
        switchError = nil
        Task(name: "Switch to \(engine) / \(bottle)") { [weak self] in
            guard let self else { return }
            switchPhase = InterfaceCopy.localized("Stopping Steam…")
            await environment.stopClient(supervisor: supervisor)
            environment.choose(engine: engine, bottle: bottle)
            followActiveBottle()
            EventLog.enqueue(.app, "switched to \(engine), bottle \(bottle)")
            switchPhase = InterfaceCopy.localized("Checking the new environment…")
            await provisioner.refreshDetection()
            if provisioner.needsSetup {
                switchPhase = InterfaceCopy.localized("Setting up the bottle…")
                await provisioner.provisionAndConfigure()
                if case let .failed(reason) = provisioner.activity {
                    // The choice stays: detection drives everything, so Repair
                    // or Try Again continues from here.
                    switchError = reason
                    // A half-provisioned bottle still gets the idempotent
                    // configuration, so it never runs with winebus polling and
                    // no renderer staged.
                    await provisioner.configureBottle(named: bottle)
                }
            } else {
                await provisioner.configureBottle(named: bottle)
            }
            refreshStandingFailure()
            if clientStartIsBlocked {
                // A prefix whose Steam installer failed has no client to start.
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
