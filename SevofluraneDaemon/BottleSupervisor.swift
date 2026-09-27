import Foundation
import os

/// Keeps the bottled Steam client alive, in the process that outlives the app.
///
/// The client is healthy only when CDP answers *and* its target list contains
/// the `SharedJSContext` page — a listening port without that page is the
/// half-wedged client. On sustained failure the supervisor restarts the
/// client: graceful `-shutdown`, then `wineserver -k`, then signals, each rung
/// only for what the previous one left alive. A new client invalidates
/// CLIENT_SESSION and the transport ports, so recovery ends by reloading the
/// app's page — the bridge's 302 re-fetches both.
///
/// Everything the page owns crosses ``AppLink``. With no app attached the
/// cycle still runs: the client is kept alive and `sevo` still answers, and
/// the page half resumes when an app comes back and attaches.
@MainActor
final class BottleSupervisor {
    typealias Health = SupervisorHealth
    typealias Fault = SupervisorFault
    typealias BootPhase = SupervisorBootPhase
    typealias HealthInputs = SupervisorHealthInputs

    private(set) var health: Health = .starting

    /// Called whenever the verdict moves, so the attached app's menu bar
    /// changes with it rather than a poll later.
    var onHealthChange: ((Health) -> Void)?

    /// Whether the client has answered at all since this daemon started, or
    /// since the last quit. Until it has, every failure is the first launch
    /// still happening.
    var hasSeenClientUp = false
    /// Whether this boot has looked for a wineserver that answers no one.
    var checkedForStaleServer = false
    /// The adopted programs whose launch is under way, from the request to
    /// the spawn. A launch awaits the companion prefix for up to a minute on
    /// its first run, and every request that arrives meanwhile would
    /// otherwise make the prefix and start the program again beside it.
    var programsStarting: Set<Int> = []
    /// When each adopted program was last spawned. Until `pgrep` has seen it
    /// or a minute has passed, a request for it is the extra click: the
    /// process takes seconds to appear under Rosetta, and two launches in
    /// that gap made two games and two frame-rate unlockers.
    var programsSpawnedAt: [Int: ContinuousClock.Instant] = [:]
    /// Seconds into a boot before Wine's log is read for "cannot connect":
    /// a launcher that cannot reach its server says so within a few seconds.
    static let staleServerCheckAfter = 12
    /// Whether this session's client has been healthy once: what tells a
    /// launch from a recovery, in the verdict and in the log.
    var hasBeenHealthy = false

    private var isPaused = false

    /// Whether anyone wants a client at all.
    ///
    /// The daemon outlives every app launch, so "the process is running" no
    /// longer means "the user is here". Until something asks — an app
    /// attaching, a control verb, or a client already running that this daemon
    /// is adopting — the cycle probes and reports but launches nothing.
    /// Without it, quitting Sevoflurane would bring the bottle down and the
    /// next probe would put it straight back up.
    var wantsClient = false
    var restartPhase = ""
    private var progressPhase: String?
    private var lastProbe: ClientLifecycle.ClientState = .down
    private var pageServicesUp = false
    var fault: Fault?
    private var boot: BootPhase = .idle
    /// When the current boot phase began: `.awaitingClient` and
    /// `.awaitingServices` have budgets of their own, so each starts a clock.
    private var bootBegan: ContinuousClock.Instant?

    private var healthInputs: HealthInputs {
        HealthInputs(
            isPaused: isPaused || !wantsClient,
            isRestarting: isRestarting,
            restartPhase: restartPhase,
            progressPhase: progressPhase ?? boot.progressText(elapsedSeconds: bootSeconds),
            isPageBooting: boot == .pageBooting,
            lastProbe: lastProbe,
            pageServicesUp: pageServicesUp,
            hasBeenHealthy: hasBeenHealthy,
            isAwaitingSignIn: isAwaitingSignIn,
            fault: fault,
        )
    }

    /// Re-derives health from the inputs as they stand. Every input change
    /// ends here, so no path can leave a stale state behind it.
    func refreshHealth() {
        let derived = Health.evaluate(healthInputs)
        guard health != derived else { return }
        health = derived
        if derived == .healthy { PerfProbe.poi.emitEvent("Healthy") }
        onHealthChange?(derived)
    }

    /// How long the current boot phase has been running.
    private var bootSeconds: Int {
        guard let bootBegan else { return 0 }
        return Int(bootBegan.duration(to: .now).components.seconds)
    }

    /// The clocks the cycle keeps, in seconds, as they stand on an idle Mac.
    /// The cycle reads them through ``patient(_:)``.
    private enum Timing {
        /// How long a launch has to bring CDP up before it is a failure.
        static let clientBoot = 180
        /// How long Steam's own services have to initialize before the page
        /// is booted without them.
        static let clientServices = 120
        /// How long a page that answers with no services is left alone.
        static let servicesGrace = 90
        /// How long a live client's DevTools server may stay mute before the
        /// client counts as down.
        static let muteClient = 30
    }

    // MARK: - The Mac the client runs on

    /// What else weighs on this Mac, read at every probe. A client that is
    /// slow on a Mac at full load is slow because of the load: the clocks
    /// stretch by ``HostPressure/patience`` and the log says why.
    private(set) var pressure = HostPressure()
    private let pressureSampler = HostPressureSampler()
    var onPressureChange: ((HostPressure) -> Void)?

    /// A clock of ``Timing`` as it stands under the current pressure.
    private func patient(_ seconds: Int) -> Int {
        Int((Double(seconds) * pressure.patience).rounded())
    }

    /// Waits for the verdict to reach healthy, for as long as a boot's own
    /// clocks allow on this Mac as loaded as it is. Answers false when it
    /// never did: the clocks ran out, supervision paused, or the supervisor
    /// gave up.
    func waitForHealthy() async -> Bool {
        let began = ContinuousClock.now
        while began.duration(to: .now)
            < .seconds(patient(Timing.clientBoot + Timing.clientServices + Timing.servicesGrace)) {
            switch health {
            case .healthy: return true
            case .gaveUp, .paused: return false
            default: try? await Task.sleep(for: .seconds(1))
            }
        }
        return health == .healthy
    }

    /// The reason for a restart or a fault, with the Mac's state beside it
    /// where that state is part of the story.
    private func withPressure(_ reason: String) -> String {
        guard pressure.isElevated else { return reason }
        return "\(reason) — on a loaded Mac: \(pressure.causes.joined(separator: "; "))"
    }

    /// Rising pressure counts at once, because a clock must stretch before
    /// it runs out; falling pressure counts once it has held, because a
    /// build breathes between steps and the log should not breathe with it.
    private func samplePressure() {
        let reading = pressureSampler.sample()
        if reading.patience < pressure.patience || (!reading.isElevated && pressure.isElevated) {
            calmerReadings += 1
            guard calmerReadings >= Self.calmerReadingsToSettle else { return }
        }
        calmerReadings = 0
        let before = pressure
        pressure = reading
        guard reading.rounded != before.rounded else { return }
        if reading.isElevated != before.isElevated || reading.patience != before.patience {
            log.log(.supervisor, reading.sentence.map {
                "host: \($0) Waits are \(Int(reading.patience))× as long."
            } ?? "host: back to ordinary levels")
        }
        onPressureChange?(reading)
    }

    private var calmerReadings = 0
    /// About fifteen seconds of probes.
    private static let calmerReadingsToSettle = 5

    var statusText: String {
        health.statusText
    }

    /// The app's half of supervision: the page, Steam's popups, and the
    /// bridge's socket to the client.
    let app: AppLink
    let log = EventLog.shared

    /// Whether the machine is waiting on a human to sign in: the page holds
    /// Steam's login popup, or the client's own boot showed its sign-in
    /// window before the page had adopted anything. Every recovery timer
    /// consults this — a signed-out client is a steady state, not a failed
    /// boot, and the reloads those timers end in are what quit Steam.
    var isAwaitingSignIn: Bool {
        app.facts.isAwaitingSignIn || clientShowsLoginWindow
    }

    /// Hands the signed-out state over to the page once its login popup
    /// exists: from there the popup is the truth, and the client's own window
    /// has been swept off screen and cannot be seen again.
    private func refreshSignInState() {
        if app.facts.isAwaitingSignIn { clientShowsLoginWindow = false }
    }

    private var loop: Task<Void, Never>?
    var clientFailures = 0
    /// When the current run of consecutive client-probe failures began; the
    /// restart decision needs a duration, not just a count.
    private var firstClientFailure = Date.distantPast
    /// A game window is on screen (from the probe's window scan).
    private var gameIsUp = false
    private var probeCycleCount = 0
    private var pageFailures = 0
    /// Reloads given to the current page outage. Two that changed nothing
    /// mean the web view itself is what is wedged, and the third try rebuilds it.
    private var pageReloads = 0
    var isRestarting = false
    /// A restart asked for while the ladder is mid-flight, with its reason.
    /// The running ladder stops waiting on the client it is bringing up and
    /// runs again from the top, so an engine switch that lands during a boot
    /// boots the new engine instead of finishing the old one first.
    var restartAgain: String?
    /// An engine or bottle to move onto once the ladder has the running
    /// client down (``switchEngine(to:bottle:)``).
    var pendingSwitch: EngineSwitch?
    /// A shader-cache clear the next ladder pass makes between its stop and
    /// its launch (``clearShaderCache()``).
    var pendingShaderCacheClear = false
    /// The provisioning failure the log has already named, so a probe that
    /// meets it again says nothing new.
    var reportedProvisioningBlock: String?
    /// The prefix outside Sevoflurane's bottles whose client the log has
    /// already named as holding the CDP port.
    var reportedOutsideClient: String?
    /// Callers of ``ladderFinished()`` waiting for the running ladder.
    var ladderWaiters: [CheckedContinuation<Void, Never>] = []
    struct EngineSwitch {
        let engine: Engine
        let bottle: String?
        /// Whether the switch becomes the stored choice. A switch the ladder
        /// found on disk by itself leaves an unnamed choice unnamed.
        var persists = true
    }
    var recentRestarts: [Date] = []
    /// The restart whose boot has not been classified yet. A boot that ends
    /// at the login window is a user who signed out, not a crash, so its
    /// entry comes back out of the crash-loop budget.
    var pendingRestart: Date?
    /// The client's own sign-in window, seen by the boot's popup sweep two
    /// seconds after launch — long before the page has adopted anything. It
    /// ends the wait for Steam's services, which a signed-out client never
    /// initializes, and hands over to the page's own login popup as soon as
    /// that exists.
    var clientShowsLoginWindow = false
    private var lastPageRecovery = Date.distantPast
    /// Whether the current services outage already got its one page reload —
    /// the next escalation is a client restart.
    private var serviceRecoveryTried = false
    /// Whether the current crash loop already got its one hygiene pass
    /// (htmlcache purge + headless client repair) — the next stop is `gaveUp`.
    var hygieneTried = false
    /// Whether the login window was up on a previous cycle. Its going away
    /// with the services still down is the "the user just signed in" edge,
    /// which needs the page reloaded rather than waited out.
    private var wasAwaitingSignIn = false
    /// Why the library is to open by itself the moment everything is healthy,
    /// or nil when it is not. The reason picks the line the log gets: a person
    /// who opened Sevoflurane and a sign-in that just finished are different
    /// stories and only one of them mentions signing in.
    private var showLibraryOnHealthy: LibraryOpening?
    /// What armed the automatic library opening.
    enum LibraryOpening: Equatable, Sendable {
        /// A person opened Sevoflurane and came for the window.
        case theUserOpenedTheApp
        /// Sign-in completed; ending in silence reads as a crash.
        case signInFinished

        var note: String {
            switch self {
            case .theUserOpenedTheApp: "the client is up — opening Steam's window"
            case .signInFinished: "sign-in finished — opening the library"
            }
        }
    }

    /// Puts Steam's window on screen as soon as the client is healthy.
    func showLibraryWhenHealthy(_ reason: LibraryOpening = .theUserOpenedTheApp) {
        showLibraryOnHealthy = reason
    }

    /// Dedupes the "Wine window visible" log line across probe cycles.
    private var wineWindowsVisible = false
    /// When the current client launch began, for the boot-audit line at the
    /// healthy transition.
    var clientStartedAt: ContinuousClock.Instant?
    /// Set once quit teardown begins; blocks every path that could relaunch
    /// the client mid-teardown.
    var isQuitting = false

    init(app: AppLink) {
        self.app = app
    }

    /// Why the probe cycle woke.
    ///
    /// Every observable death wakes the cycle; the interval is a ceiling on
    /// how long an unobservable change can hide.
    nonisolated enum Wake: Equatable, Sendable {
        case tick
        case launcherExited(Int32)
        /// The bridge lost its transport to the client. It knows first: the
        /// relay closed four seconds before the launcher exited.
        case clientConnectionLost
        /// A control verb asked for a cycle rather than waiting one out.
        case control(String)
        case gameWindowChanged

        /// What the log says when this wake starts a cycle. The tick is the
        /// ordinary case and says nothing.
        var note: String? {
            switch self {
            case .tick: nil
            case let .launcherExited(status): "the wine launcher exited (status \(status))"
            case .clientConnectionLost: "the client's transport closed"
            case let .control(verb): verb
            case .gameWindowChanged: "a game window appeared or went away"
            }
        }
    }

    private var wakeups: AsyncStream<Wake>.Continuation?
    private var pendingTick: Task<Void, Never>?

    func start() {
        guard loop == nil else { return }
        // The page the app just booted needs time to reach the bridge before
        // an unanswered probe means anything.
        lastPageRecovery = .now
        let (wakes, continuation) = AsyncStream<Wake>.makeStream(
            bufferingPolicy: .bufferingNewest(8),
        )
        wakeups = continuation
        // The launcher's termination handler runs on its own queue, so the
        // hop is a fire-and-forget onto the actor the supervisor lives on.
        ClientLifecycle.clientDidExit = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.wake(.launcherExited(status)) }
            }
        }
        log.log(.supervisor, "supervision started (probing CDP :\(BridgePorts.cdp), bridge :\(BridgePorts.steamUI))")
        loop = Task(name: "Client supervision") { [weak self] in
            for await reason in wakes {
                guard let self else { return }
                if let note = reason.note {
                    log.log(.supervisor, "probe cycle woken: \(note)")
                }
                await probe()
                scheduleTick()
            }
        }
        wake(.tick)
    }

    /// A new app process is rendering Steam. Its page is seconds old, so the
    /// recovery clocks start again from here — without this, a page that has
    /// existed for two seconds is measured against a grace that ran out while
    /// no app was running at all, and the first thing a relaunched app gets is
    /// a reload.
    func appDidAttach() {
        lastPageRecovery = .now
        pageFailures = 0
        pageReloads = 0
        serviceRecoveryTried = false
        refreshHealth()
    }

    /// Something asked for a client: an app attached, or a control verb
    /// arrived. Idempotent, and the first ask starts a cycle rather than
    /// waiting one out.
    func wantClient(because reason: String) {
        guard !wantsClient else { return }
        wantsClient = true
        log.log(.supervisor, "supervision is live: \(reason)")
        refreshHealth()
        wake(.control(reason))
    }

    /// Runs a cycle now. Coalescing is the stream's: a burst of wakes while a
    /// cycle is running collapses into the one cycle that follows it.
    func wake(_ reason: Wake) {
        wakeups?.yield(reason)
    }

    /// Arms the next tick at the current interval — a ceiling, re-read after
    /// every cycle so a game coming up or going away moves it at once.
    private func scheduleTick() {
        pendingTick?.cancel()
        let interval = probeInterval
        pendingTick = Task(name: "Probe tick") { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            self?.wake(.tick)
        }
    }

    /// The probe cadence: quick while converging or recovering, relaxed
    /// while healthy, and near-dormant while a game has the machine — the
    /// game is the workload the whole app exists for, and a supervisor that
    /// scans windows and opens DevTools sessions every eight seconds during
    /// play is taking CPU from it. `.starting` is the page-just-reloaded
    /// convergence window: the healthy transition rides a probe tick, so a
    /// second-by-second cadence there is seconds off every boot audit
    /// (`probeClient` is one HTTP `/json` fetch — no DevTools session).
    private var probeInterval: Duration {
        if boot == .awaitingClient || boot == .awaitingServices {
            // CDP arrives at an arbitrary moment past ~15 s, and each stride
            // of slack past that is a second on every boot audit.
            return bootSeconds < 15 ? .seconds(3) : .seconds(1)
        }
        switch health {
        case .healthy: return gameIsUp ? .seconds(60) : .seconds(8)
        case .starting: return .seconds(1)
        default: return .seconds(3)
        }
    }

    /// Pausing is about this app, not about Steam, so it is a flag rather than
    /// a health value: a health value is overwritten by whatever assigns
    /// health next, and a pause that a restart ladder can silently undo is
    /// not a pause.
    func setPaused(_ paused: Bool, note: String) {
        guard isPaused != paused else { return }
        isPaused = paused
        if !paused {
            clientFailures = 0
            pageFailures = 0
            pageServicesUp = false
            fault = nil
        }
        log.log(.supervisor, note)
        refreshHealth()
        if !paused { wake(.control(note)) }
    }

    // MARK: - Probe cycle

    private func probe() async {
        samplePressure()
        if isPaused || isRestarting || isQuitting {
            // The display hold follows the game, whatever the client is
            // doing: a game that exits during a client restart releases it
            // on this cycle.
            if gameIsUp { _ = await observeWineWindows() }
            return
        }
        probeCycleCount += 1
        let cycle = PerfProbe.supervisor.beginInterval("ProbeCycle")
        await probeChain()
        PerfProbe.supervisor.endInterval(
            "ProbeCycle", cycle, "\(self.statusText, privacy: .public)",
        )
    }

    private func probeChain() async {
        refreshSignInState()
        // Progress is what this cycle finds, never what a previous one left;
        // and a fault the cycle no longer sees is gone. `gaveUp` is the
        // exception: nothing re-asserts a crash loop, so it stands until the
        // client answers or a human asks for a restart.
        progressPhase = nil
        if case .degraded = fault { fault = nil }
        let wineWindows = await observeWineWindows()

        let clientProbe = PerfProbe.supervisor.beginInterval("ClientProbe")
        let client = await ClientLifecycle.probeClient()
        PerfProbe.supervisor.endInterval(
            "ClientProbe", clientProbe, "\(String(describing: client), privacy: .public)",
        )
        lastProbe = client
        guard client == .up else {
            await handleClientDown(client, wineWindows: wineWindows)
            refreshHealth()
            return
        }
        // A client is adopted only once it is known to be the configured
        // bottle's: CDP is one fixed port, and any bottle's client can hold it.
        let sweepIdentity = !hasSeenClientUp
            || (health == .healthy && !gameIsUp && probeCycleCount.isMultiple(of: 8))
        guard await confirmClientIdentity(sweep: sweepIdentity) else {
            refreshHealth()
            return
        }
        clientFailures = 0
        hasSeenClientUp = true
        wantClient(because: "a client is already running")
        if case .gaveUp = fault {
            fault = nil
            log.log(.supervisor, "client recovered on its own")
        }

        // The client renders nothing here — a CEF window it opened for
        // itself (the first-run login window) is hidden as soon as it shows,
        // and the page's native mirror of the same popup is what the user
        // sees. The sweep opens a DevTools session per CEF popup target, so
        // it runs every cycle only while converging; a healthy steady state
        // sweeps every eighth cycle, and a running game suspends it.
        // `.awaitingClient` is the cycle that connects the bridge, and the
        // sweep runs over that connection — so this one sweeps at the end of
        // the connect instead, and finds the login window on the first cycle
        // rather than the second.
        if !gameIsUp, boot != .awaitingClient,
           boot != .idle || health != .healthy || probeCycleCount.isMultiple(of: 8) {
            await sweepClientPopups(duringStartup: boot != .idle)
        }

        if await advanceBoot() {
            refreshHealth()
            return
        }

        guard app.isAttached else {
            // Nothing is rendering Steam, so there is no page to probe and
            // nothing to reload: a client that answers CDP is as healthy as
            // this cycle can tell, and it stays up until an app attaches and
            // says otherwise.
            endBoot()
            pageServicesUp = true
            refreshHealth()
            return
        }
        await reactToPage(wineWindows: wineWindows)
        refreshHealth()
    }

    /// Moves the client's boot on by one step, and answers whether the boot
    /// owns this cycle. Every wait on the client's boot is a step here, so
    /// the guards the cycle owns — the login window above all — are on
    /// throughout.
    private func advanceBoot() async -> Bool {
        switch boot {
        case .idle, .pageBooting:
            return false
        case .awaitingClient:
            let waited = bootSeconds
            PerfProbe.poi.emitEvent("ClientBack", "up after ~\(waited)s")
            log.log(.client, "client is back — CDP + SharedJSContext up after ~\(waited)s")
            progressPhase = "connecting to the client"
            refreshHealth()
            await app.connectToClient()
            await sweepClientPopups(duringStartup: true)
            enterBoot(.awaitingServices)
            progressPhase = boot.progressText(elapsedSeconds: bootSeconds)
            return true
        case .awaitingServices:
            progressPhase = boot.progressText(elapsedSeconds: bootSeconds)
            guard app.isAttached else {
                log.log(.client, "client is up with no app attached — the boot ends here")
                endBoot()
                return false
            }
            if isAwaitingSignIn {
                // A signed-out client never initializes its services, so the
                // sign-in window ends this wait as decisively as the services
                // arriving. The page is left as it is: a reload over the
                // login window quits Steam.
                log.log(.client, "the client is showing its sign-in window — waiting for sign-in")
                await bootPage()
                dropPendingRestart()
                return true
            }
            if await ClientLifecycle.clientServicesReady() == true {
                log.log(.client, "client services ready — booting the page with a live session")
                await bootPage()
            } else if bootSeconds >= patient(Timing.clientServices) {
                log.log(.client, "client services did not arrive in time — booting the page anyway")
                await bootPage()
            }
            return true
        }
    }

    /// Starts a boot phase and its clock.
    func enterBoot(_ phase: BootPhase) {
        boot = phase
        bootBegan = .now
        checkedForStaleServer = false
    }

    func endBoot() {
        boot = .idle
        bootBegan = nil
    }

    private func reactToPage(wineWindows: [WineWindowWatch.Window]) async {
        switch await PageProbe.state() {
        case .bridgeDown:
            endBoot()
            pageServicesUp = false
            fault = .degraded("bridge is down — relaunch Sevoflurane")
            transition(
                logging: .bridge,
                "in-process bridge on :\(BridgePorts.steamUI) is unreachable",
            )
        case let .notAnswering(detail):
            await recoverSilentPage(detail: detail)
        case .answering(servicesUp: false):
            endBoot()
            pageServicesUp = false
            await recoverDeadServices(wineWindows: wineWindows)
        case .answering(servicesUp: true):
            await noteEverythingUp(wineWindows: wineWindows)
        }
    }

    /// The page is up but not answering: a second failure in a row reloads the
    /// UI, and a page two reloads did not fix is rebuilt.
    private func recoverSilentPage(detail: String) async {
        endBoot()
        pageServicesUp = false
        pageFailures += 1
        if pageFailures >= 2,
           Date.now.timeIntervalSince(lastPageRecovery) > Double(patient(Timing.servicesGrace)) {
            lastPageRecovery = .now
            pageFailures = 0
            if pageReloads >= 2 {
                log.log(
                    .page,
                    "page not answering with a healthy client after \(pageReloads) reloads "
                        + "(\(detail)) — rebuilding the UI page",
                )
                pageReloads = 0
                await app.send(.rebuild)
                fault = .degraded("rebuilding the UI…")
            } else {
                log.log(.page, "page not answering with a healthy client (\(detail)) — reloading the UI")
                pageReloads += 1
                await app.send(.reload)
                fault = .degraded("reloading the UI…")
            }
        } else {
            fault = .degraded("page not answering (\(detail))")
            transition(logging: .page, "page not answering: \(detail)")
        }
    }

    /// Client, bridge, page and Steam's services all answer: the recovery
    /// counters reset, and a boot that just finished is audited and followed
    /// by whatever was waiting on it.
    private func noteEverythingUp(wineWindows: [WineWindowWatch.Window]) async {
        endBoot()
        hasBeenHealthy = true
        pageServicesUp = true
        pageFailures = 0
        pageReloads = 0
        serviceRecoveryTried = false
        hygieneTried = false
        wasAwaitingSignIn = false
        clientShowsLoginWindow = false
        pendingRestart = nil
        // steam.exe windows are VGUI dialogs (rescue/update/EULA) and
        // worth surfacing as a state; webhelper windows are leaked client
        // web UI (notification toasts) — logged on appearance, not a
        // health downgrade.
        if wineWindows.contains(where: { $0.owner.lowercased() == "steam.exe" }) {
            fault = .degraded("Steam surfaced a dialog — see the log")
            transition(
                logging: .supervisor,
                "everything probes healthy but a steam.exe dialog is up — reporting, not acting",
            )
        } else {
            let becameHealthy = health != .healthy
            fault = nil
            transition(
                logging: .supervisor,
                "healthy: client, bridge, page, and Steam services all up",
            )
            if becameHealthy, let began = clientStartedAt {
                clientStartedAt = nil
                log.log(
                    .supervisor,
                    "boot audit: \(began.duration(to: .now).components.seconds)s "
                        + "from launch to healthy",
                )
            }
            if becameHealthy, let opening = showLibraryOnHealthy {
                showLibraryOnHealthy = nil
                log.log(.supervisor, opening.note)
                await app.send(.showLibrary)
            }
            // Explorer exists to suppress right after the client comes
            // up; afterwards an occasional sweep catches a respawn
            // (whether a game launch respawns it is an open watch item).
            if !gameIsUp, becameHealthy || probeCycleCount.isMultiple(of: 8) {
                Task(name: "Wine tray suppression") { await Self.suppressWineTray() }
            }
        }
    }

    /// A visible Wine window is an anomaly (the client is -silent): most
    /// often Steam's own watchdog dialog. It is a symptom, never a control
    /// surface — when probes are failing too it confirms the wedge and
    /// skips the usual second-confirmation cycle; on its own it is
    /// reported and left alone (an update or EULA prompt may be legit).
    /// Appearance and disappearance are each logged once.
    private func observeWineWindows() async -> [WineWindowWatch.Window] {
        let scan = await WineWindowWatch.scan()
        if scan.gameWindowUp != gameIsUp {
            gameIsUp = scan.gameWindowUp
            // The launch watch holds the display the moment the window
            // appears; this scan is the authoritative edge for games it
            // missed and for the exit.
            if let game = scan.game {
                GameDisplayHold.gameDidAppear(for: "\(game.owner) (pid \(game.pid))")
            } else {
                GameDisplayHold.gameDidExit()
            }
            wake(.gameWindowChanged)
        }
        let wineWindows = scan.wineWindows
        if !wineWindows.isEmpty, !wineWindowsVisible {
            wineWindowsVisible = true
            log.log(
                .client,
                "Wine window visible: \(WineWindowWatch.describe(wineWindows)) "
                    + "— Steam surfaced UI (its watchdog dialog, or an update/EULA prompt)",
            )
        } else if wineWindows.isEmpty, wineWindowsVisible {
            wineWindowsVisible = false
            log.log(.client, "Wine windows gone")
        }
        return wineWindows
    }

    private func handleClientDown(
        _ client: ClientLifecycle.ClientState,
        wineWindows: [WineWindowWatch.Window],
    ) async {
        let reason = switch client {
        case .portWithoutContext: "CDP is up but lists no SharedJSContext — half-wedged client"
        case .busy: "CDP is slow to answer — the client is busy"
        default: "CDP unreachable — client down"
        }
        clientFailures += 1
        if clientFailures == 1 { firstClientFailure = .now }
        if case .gaveUp = fault { return }
        if boot == .awaitingClient {
            advanceBootWait(wineWindows: wineWindows)
            return
        }
        // A dead process is down; a mute DevTools server on a live process is
        // slow until it has been mute for half a minute. A swapped-out CEF
        // misses short `/json` timeouts, and each restart that reads that as
        // a death is a two-minute outage.
        let processAlive = await ClientLifecycle.clientProcessAlive()
        // A DevTools server that accepted the connection and said nothing, on
        // a client whose transport is still open, is under load rather than
        // gone: the socket the bridge holds is the second opinion `/json`
        // alone cannot give.
        let clientSocketOpen = app.facts.isClientConnected
        // That opinion holds for four mute windows; a client busy past them is
        // wedged with its socket open. A game on screen keeps it holding,
        // since the game is the load and a restart would take Steam from it.
        let muteFor = Date.now.timeIntervalSince(firstClientFailure)
        let busyButConnected = client == .busy && clientSocketOpen
            && (gameIsUp || muteFor < Double(patient(Timing.muteClient) * 4))
        let deadLongEnough = !busyButConnected && clientFailures >= 3
            && muteFor >= Double(patient(Timing.muteClient))
        if !wineWindows.isEmpty, hasSeenClientUp {
            await restartClient(
                reason: reason + " with a Wine dialog up — Steam's own watchdog likely fired",
            )
        } else if !processAlive || deadLongEnough {
            let cause = if processAlive {
                withPressure(reason + " for \(Int(Date.now.timeIntervalSince(firstClientFailure)))s")
            } else if hasSeenClientUp {
                "the client process is gone"
            } else {
                "starting the client"
            }
            await restartClient(reason: cause)
        } else if hasSeenClientUp {
            fault = .degraded(withPressure(reason))
            transition(logging: .client, withPressure(reason))
        }
    }

    /// The launch is still converging: CDP arrives at an arbitrary moment past
    /// ~15 s and a first-ever boot may show the updater for minutes, so the
    /// cycle reports progress rather than restarting into a client that is on
    /// its way. Every other failure path stays live throughout.
    private func advanceBootWait(wineWindows: [WineWindowWatch.Window]) {
        let waited = bootSeconds
        let limit = patient(Timing.clientBoot)
        if waited >= limit {
            endBoot()
            let reason = withPressure("client did not come back within \(limit)s of launch")
            fault = .degraded(reason)
            transition(logging: .client, reason)
            return
        }
        // A launch against a wineserver that answers no one exits at once,
        // and every relaunch does the same until that server is gone.
        if waited >= Self.staleServerCheckAfter, !checkedForStaleServer {
            checkedForStaleServer = true
            if let stale = StaleWineserver.pid(in: StaleWineserver.logTail()), StaleWineserver.end(stale) {
                log.log(.client, "boot audit: ended wineserver \(stale), which held the bottle and answered no one")
                endBoot()
                return
            }
        }
        // A Wine window with CDP still dead this far in is Steam saying
        // something instead of starting, and waiting out the full budget
        // hides it. Only once the session has had a working client: a
        // first-ever boot may legitimately show the updater for minutes while
        // it applies staged packages.
        if waited >= 24, hasSeenClientUp, !wineWindows.isEmpty {
            log.log(
                .client,
                "boot audit: wedged — " + WineWindowWatch.describe(wineWindows)
                    + " up with CDP dead after \(waited)s; the ladder decides from here",
            )
            endBoot()
            return
        }
        progressPhase = boot.progressText(elapsedSeconds: waited)
    }

    /// One pass over the client's own CEF popups: each visible one is put away
    /// (the page renders these natively) and a sign-in window among them is
    /// remembered.
    private func sweepClientPopups(duringStartup: Bool) async {
        let hidden = await ClientLifecycle.hideVisibleClientPopups()
        guard !hidden.isEmpty else { return }
        if hidden.contains(where: ClientLifecycle.isLoginWindow) {
            clientShowsLoginWindow = true
        }
        log.log(
            .client,
            duringStartup
                ? "hid the client's own CEF window during startup: "
                + hidden.joined(separator: ", ")
                : "hid the client's own CEF window: \(hidden.joined(separator: ", ")) "
                + "— the page renders these natively",
        )
    }

    /// Boots the app's page at the client that just came up: a new client
    /// invalidates CLIENT_SESSION and the transport ports, so the page has to
    /// come again through the bridge's 302.
    ///
    /// Refused while the page holds Steam's login window. The reload detaches
    /// that popup, Steam reads its document unloading as the user closing the
    /// sign-in window, and closing it quits — the kill that turned five
    /// signed-out boots into five dead clients.
    private func bootPage() async {
        lastPageRecovery = .now
        pageFailures = 0
        progressPhase = nil
        guard !app.facts.isAwaitingSignIn else {
            log.log(.page, "signed out with the login window up — leaving the page as it is")
            endBoot()
            return
        }
        await app.send(.reload)
        enterBoot(.pageBooting)
    }

    /// Drops the restart that led here from the crash-loop budget. A boot
    /// that ends at the login window is a user who signed out, and three
    /// sign-outs in ten minutes are not a crash loop.
    private func dropPendingRestart() {
        guard let stamp = pendingRestart else { return }
        pendingRestart = nil
        recentRestarts.removeAll { $0 == stamp }
    }

    /// The page answers but Steam's stores never initialized. Boot and reload
    /// both need time to log in and fill the stores; past that, a reload is
    /// the cheap try, and a client whose UI session died (splash freeze,
    /// "Sign in to Steam") needs the full restart — a reload alone reattaches
    /// to the same dead session.
    private func recoverDeadServices(wineWindows: [WineWindowWatch.Window]) async {
        if clientShowsLoginWindow, !app.facts.isAwaitingSignIn,
           await ClientLifecycle.clientServicesReady() == true {
            // The client signed itself in behind the sign-in window its boot
            // showed, before the page adopted that window. Nothing else would
            // clear the boot's sighting: the page never held the popup, and
            // its services wait on the reload below, which waits on sign-in.
            clientShowsLoginWindow = false
            log.log(.client, "the client signed in by itself — its sign-in window is gone")
        }
        if isAwaitingSignIn {
            // A signed-out bottle's services never initialize until the user
            // signs in — the login window being up means the machine is
            // waiting on a human, not wedged. Holding the recovery clock
            // keeps the reload/restart ladder from tearing the login window
            // down mid-type, and gives services a fresh grace once sign-in
            // completes.
            wasAwaitingSignIn = true
            lastPageRecovery = .now
            serviceRecoveryTried = false
            dropPendingRestart()
            transition(
                logging: .supervisor,
                "Steam services down with the login window up — waiting for sign-in",
            )
            return
        }
        if wasAwaitingSignIn {
            // Sign-in just finished. A page that booted signed out never
            // initializes its services in place — the client's own CEF
            // reloads `SharedJSContext` at this point, and the page has to
            // do the same. Without this the 90s grace below runs in full
            // and the user watches Steam's spinner for a minute and a half
            // before the reload that actually finishes the job.
            wasAwaitingSignIn = false
            lastPageRecovery = .now
            pageFailures = 0
            // The library opens by itself once everything is up: sign-in
            // ending in silence reads as a crash.
            showLibraryOnHealthy = .signInFinished
            let promoted = Self.promotedBottlePIDs()
            if !promoted.isEmpty {
                // Showing the login window made winemac.drv promote its
                // process into the Dock, permanently — a Steam-iconed "wine"
                // that does nothing when clicked. The only way out is for
                // the promoted processes to exit; a signed-in client never
                // shows a window, so the restarted one stays out of the
                // Dock. (TransformProcessType on another process is procNotFound;
                // there is no demotion API.)
                log.log(
                    .client,
                    "signed in — restarting the client to shed the Wine Dock icon "
                        + "(promoted pids \(promoted))",
                )
                await restartClient(reason: "finishing sign-in")
                return
            }
            log.log(.page, "signed in — reloading the UI so the page boots with a session")
            await app.send(.reload)
            enterBoot(.pageBooting)
            return
        }
        guard Date.now.timeIntervalSince(lastPageRecovery) > Double(patient(Timing.servicesGrace)) else {
            // Not a fault: the page is up and Steam's stores are still
            // filling, which is what a first run looks like from the outside.
            // It reports as progress, never as degraded.
            progressPhase = "waiting for Steam's services…"
            transition(logging: .page, "page up, Steam services not initialized yet")
            return
        }
        if !wineWindows.isEmpty {
            // Services dead with a Wine dialog up is the known rescue-
            // dialog wedge: the webhelper is gone, a
            // reload would reattach to the same dead session.
            log.log(.client, "services dead with a Wine dialog up — restarting the client")
            await restartClient(reason: "client UI session dead, Steam's watchdog dialog visible")
        } else if serviceRecoveryTried {
            log.log(
                .client,
                "Steam services still down after a reload — "
                    + "the client's UI session is dead; restarting the client",
            )
            await restartClient(reason: "client UI session dead (services never initialized)")
        } else {
            serviceRecoveryTried = true
            log.log(.page, "Steam services never initialized — reloading the UI")
            lastPageRecovery = .now
            await app.send(.reload)
            fault = .degraded("reloading the UI…")
        }
    }

    /// Re-derives health after a caller has changed the inputs, and logs the
    /// message only if the verdict actually moved: the cycle re-asserts the
    /// same state every second and the log is for transitions.
    func transition(logging category: EventLog.Category, _ message: String) {
        let before = health
        refreshHealth()
        guard health != before else { return }
        log.log(category, message)
    }
}
