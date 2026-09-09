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

    /// Whether the client has answered at all since the app started. Until it
    /// has, every failure is the first launch still happening.
    @ObservationIgnored private var hasSeenClientUp = false

    @ObservationIgnored private var isPaused = false
    @ObservationIgnored private var restartPhase = ""
    @ObservationIgnored private var progressPhase: String?
    @ObservationIgnored private var lastProbe: ClientLifecycle.ClientState = .down
    @ObservationIgnored private var pageServicesUp = false
    @ObservationIgnored private var fault: Fault?
    @ObservationIgnored private var boot: BootPhase = .idle
    /// When the current boot phase began: `.awaitingClient` and
    /// `.awaitingServices` have budgets of their own, so each starts a clock.
    @ObservationIgnored private var bootBegan: ContinuousClock.Instant?

    private var healthInputs: HealthInputs {
        HealthInputs(
            isPaused: isPaused,
            isRestarting: isRestarting,
            restartPhase: restartPhase,
            progressPhase: progressPhase,
            isPageBooting: boot == .pageBooting,
            lastProbe: lastProbe,
            pageServicesUp: pageServicesUp,
            hasSeenClientUp: hasSeenClientUp,
            isAwaitingSignIn: isAwaitingSignIn,
            fault: fault,
        )
    }

    /// Re-derives health from the inputs as they stand. Every input change
    /// ends here, so no path can leave a stale state behind it.
    private func refreshHealth() {
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

    /// The clocks the cycle keeps, in seconds.
    private enum Timing {
        /// How long a launch has to bring CDP up before it is a failure.
        static let clientBoot = 180
        /// How long Steam's own services have to initialize before the page
        /// is booted without them.
        static let clientServices = 120
        /// How long a page that answers with no services is left alone.
        static let servicesGrace: TimeInterval = 90
    }

    var statusText: String {
        health.statusText
    }

    /// The app's half of supervision: the page, Steam's popups, and the
    /// bridge's socket to the client.
    private let app: AppLink
    private let log = EventLog.shared

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

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var clientFailures = 0
    /// When the current run of consecutive client-probe failures began; the
    /// restart decision needs a duration, not just a count.
    @ObservationIgnored private var firstClientFailure = Date.distantPast
    /// A game window is on screen (from the probe's window scan).
    @ObservationIgnored private var gameIsUp = false
    @ObservationIgnored private var probeCycleCount = 0
    @ObservationIgnored private var pageFailures = 0
    /// Reloads given to the current page outage. Two that changed nothing
    /// mean the web view itself is what is wedged, and the third try rebuilds it.
    @ObservationIgnored private var pageReloads = 0
    @ObservationIgnored private var isRestarting = false
    /// A restart asked for while the ladder is mid-flight, with its reason.
    /// The running ladder stops waiting on the client it is bringing up and
    /// runs again from the top, so an engine switch that lands during a boot
    /// boots the new engine instead of finishing the old one first.
    @ObservationIgnored private var restartAgain: String?
    @ObservationIgnored private var recentRestarts: [Date] = []
    /// The restart whose boot has not been classified yet. A boot that ends
    /// at the login window is a user who signed out, not a crash, so its
    /// entry comes back out of the crash-loop budget.
    @ObservationIgnored private var pendingRestart: Date?
    /// The client's own sign-in window, seen by the boot's popup sweep two
    /// seconds after launch — long before the page has adopted anything. It
    /// ends the wait for Steam's services, which a signed-out client never
    /// initializes, and hands over to the page's own login popup as soon as
    /// that exists.
    @ObservationIgnored private var clientShowsLoginWindow = false
    @ObservationIgnored private var lastPageRecovery = Date.distantPast
    /// Whether the current services outage already got its one page reload —
    /// the next escalation is a client restart.
    @ObservationIgnored private var serviceRecoveryTried = false
    /// Whether the current crash loop already got its one hygiene pass
    /// (htmlcache purge + headless client repair) — the next stop is `gaveUp`.
    @ObservationIgnored private var hygieneTried = false
    /// Whether the login window was up on a previous cycle. Its going away
    /// with the services still down is the "the user just signed in" edge,
    /// which needs the page reloaded rather than waited out.
    @ObservationIgnored private var wasAwaitingSignIn = false
    /// Set when sign-in completes so the library opens by itself the moment
    /// everything is healthy.
    @ObservationIgnored private var showLibraryOnHealthy = false
    /// Dedupes the "Wine window visible" log line across probe cycles.
    @ObservationIgnored private var wineWindowsVisible = false
    /// When the current client launch began, for the boot-audit line at the
    /// healthy transition.
    @ObservationIgnored private var clientStartedAt: ContinuousClock.Instant?
    /// Set once quit teardown begins; blocks every path that could relaunch
    /// the client mid-teardown.
    @ObservationIgnored private var isQuitting = false

    init(app: AppLink) {
        self.app = app
    }

    /// Why the probe cycle woke.
    ///
    /// The loop used to be `probe(); sleep(interval)`, so the interval *was*
    /// the latency: a client that died with a game up went unnoticed for 58 s,
    /// which is the 60 s cadence a running game earns. Every death that can be
    /// observed directly arrives here instead, and the interval becomes a
    /// ceiling on how long an unobservable change can hide.
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

    @ObservationIgnored private var wakeups: AsyncStream<Wake>.Continuation?
    @ObservationIgnored private var pendingTick: Task<Void, Never>?

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

    func togglePaused() {
        setPaused(!isPaused, note: isPaused ? "auto-restart resumed" : "auto-restart paused")
    }

    /// Pausing is about this app, not about Steam, so it is a flag rather than
    /// a health value: a health value is overwritten by whatever assigns
    /// health next, and a pause that a restart ladder can silently undo is
    /// not a pause.
    private func setPaused(_ paused: Bool, note: String) {
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

    /// Starts a game, restarting the client first when that game is pinned to
    /// a renderer the running session does not have.
    ///
    /// The renderer reaches a game through the environment of the process
    /// tree Steam already lives in, so there is no way to change it for one
    /// game without a new tree. The menu bar says so before the click; this
    /// is the click.
    func launch(appID: Int, name: String, renderer explicit: Renderer? = nil) async {
        // The desired renderer for this launch — an explicit "Run with X" wins
        // over a persistent pin, and neither persists past the launch beyond
        // the bottle default it sets.
        let desired = explicit ?? BottleGraphics.overrides()[appID]?.renderer
        if let desired, desired != BottleGraphics.currentSelection().renderer {
            do {
                let current = BottleGraphics.currentSelection()
                try BottleGraphics.applyToActiveEngine(
                    BottleGraphics.Selection(
                        renderer: desired, msync: current.msync, gpu: current.gpu,
                    ),
                )
            } catch {
                log.log(.client, "could not set \(desired.label) for \(name): \(error)")
            }
        }

        let change = BottleGraphics.graphicsChangeSinceBoot()
        let mustBounce = change.bounce
            || (change.restage && !BottleGraphics.hotRestageSupported)

        if mustBounce {
            // msync or the engine moved: a fresh wineserver is owed, so the
            // client restarts and the spawn reconciles the tree.
            log.log(.client, "\(name) needs a client restart for its graphics")
            recentRestarts.removeAll()
            hygieneTried = false
            await restartClient(reason: "graphics change for \(name)")
            // The client is up and the page reloaded; Steam's own services
            // need a moment more before a launch request means anything.
            for _ in 0 ..< 40 where health != .healthy {
                try? await Task.sleep(for: .seconds(3))
            }
        } else if change.restage {
            // Hot: only the renderer or D3DMetal version moved. Restage the
            // tree under the running client; the game loads the new DLLs when
            // it launches, and the booted record now matches.
            log.log(.client, "restaging graphics for \(name) without a restart")
            if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
                log.log(.client, note)
            }
            BottleGraphics.recordBootedSelection()
        }
        await app.launchGame(appID: appID)
    }

    /// The menu-bar button and the control endpoint: restarts
    /// unconditionally, with a fresh crash-loop budget — the user asking is
    /// what distinguishes "try again" from a loop. A ladder already in flight
    /// runs again rather than being fought or refused.
    func restartNow(reason: String = "manual restart from the menu bar") {
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual client restart") {
            await restartClient(reason: reason)
        }
    }

    /// The heavier menu-bar restart: the whole fake Windows comes down and
    /// boots fresh — for when the machine itself is suspect, not just Steam.
    func restartWindowsNow() {
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual Windows restart") {
            await restartClient(
                reason: "manual Windows restart from the menu bar",
                fullWindows: true,
            )
        }
    }

    /// The escape hatch when a graceful restart is itself hung: SIGKILL the
    /// Steam client straight away, then bring it back clean. `everything`
    /// takes the whole fake machine — games and services included — down
    /// first. The crash-loop budget resets because the user asked.
    func forceQuit(_ scope: ClientLifecycle.ForceScope) {
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Force quit \(scope == .steam ? "Steam" : "everything")") {
            let killed = await ClientLifecycle.forceQuit(scope)
            log.log(
                .client,
                "force-quit \(scope == .steam ? "Steam" : "everything")"
                    + " — \(killed.count) process(es) killed, restarting clean",
            )
            await restartClient(
                reason: "force-quit from the menu bar",
                fullWindows: scope == .everything,
            )
        }
    }

    /// Whether the restart ladder is mid-flight — control verbs that would
    /// race it (`sevo client stop`) refuse instead of interleaving.
    var isBusyRestarting: Bool {
        isRestarting
    }

    /// `sevo client stop`: pauses supervision (so nothing relaunches the
    /// client behind the CLI's back) and brings the bottle down.
    func stopForControl() async {
        guard !isQuitting, !isRestarting else { return }
        endBoot()
        setPaused(true, note: "auto-restart paused (sevo client stop)")
        // A deliberate stop should look like one: the app's own library
        // window comes down first (left up it freezes dimmed over the whole
        // stop), and the client's shutdown dialog is hidden as it exits.
        await app.send(.dismissWindows)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true)
        }
        log.log(.supervisor, "client stopped (sevo)")
    }

    /// Whether a provisioning failure is holding the client down: the last
    /// setup pass for this engine and bottle stopped at a stage that leaves
    /// nothing to start, and nobody has retried it or asked for the client
    /// anyway (Settings › Engine). Says so in the log once per attempt,
    /// because a client that never comes up is otherwise a mystery.
    func provisioningBlocksStart(reason: String) -> Bool {
        guard let failure = BottleReadiness.clientStartBlock else { return false }
        log.log(
            .supervisor,
            "not starting the client (\(reason)): the bottle is unfinished — \(failure)",
        )
        return true
    }

    /// `sevo client start`: resumes supervision, and restarts the client if
    /// it is not already up — the supervisor's ladder, not a bare launch.
    func startForControl() {
        setPaused(false, note: "auto-restart resumed (sevo client start)")
        Task(name: "sevo client start") {
            if await ClientLifecycle.probeClient() != .up {
                await restartClient(reason: "sevo client start")
            }
        }
    }

    /// Quit teardown: quitting Sevoflurane quits Steam. Stops supervision so
    /// nothing relaunches the client, then brings every bottle process down —
    /// the client's processes are launched detached, so without this they
    /// outlive the session (and a leaked webhelper window parks a dead icon
    /// in the Dock). Reached only from `/quit` and `SIGTERM`: a bottle that
    /// nobody asked to come down keeps running, which is the whole of what
    /// surviving an app crash means.
    func shutdownForQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        pendingTick?.cancel()
        pendingTick = nil
        wakeups?.finish()
        wakeups = nil
        loop?.cancel()
        loop = nil
        log.log(.supervisor, "quit: bringing the bottle down")
        // The last thing a user sees of this app is the teardown, so the
        // popup sweep runs here too: the client puts up "Shutting down
        // Steam…" on its way out, and a quit is the one moment nothing else
        // is left to hide it.
        await app.send(.dismissWindowsForQuit)
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 8, hidingPopups: true)
        }
        let survivors = await ClientLifecycle.bottleProcessIDs()
        log.log(
            .supervisor,
            survivors.isEmpty
                ? "quit: bottle is down"
                : "quit: pids \(survivors) survived SIGKILL",
        )
    }

    // MARK: - Probe cycle

    private func probe() async {
        if isPaused || isRestarting || isQuitting { return }
        probeCycleCount += 1
        let cycle = PerfProbe.supervisor.beginInterval("ProbeCycle")
        await probeChain()
        PerfProbe.supervisor.endInterval(
            "ProbeCycle", cycle, "\(self.statusText, privacy: .public)",
        )
    }

    private func probeChain() async {
        app.reapIfGone()
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
        clientFailures = 0
        hasSeenClientUp = true
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
        if !gameIsUp, boot != .idle || health != .healthy
            || probeCycleCount.isMultiple(of: 8) {
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
    /// owns this cycle. Every wait the restart ladder used to make on the
    /// client's behalf is a step here instead, so the guards the cycle owns —
    /// the login window above all — are on throughout.
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
            enterBoot(.awaitingServices)
            progressPhase = "waiting for Steam's services…"
            return true
        case .awaitingServices:
            progressPhase = "waiting for Steam's services…"
            if isAwaitingSignIn {
                // A signed-out client never initializes its services, so the
                // sign-in window ends this wait as decisively as the services
                // arriving. Two minutes of waiting followed by a reload is
                // how it used to end, and the reload is what quit Steam.
                log.log(.client, "the client is showing its sign-in window — waiting for sign-in")
                await bootPage()
                dropPendingRestart()
                return true
            }
            if await ClientLifecycle.clientServicesReady() == true {
                log.log(.client, "client services ready — booting the page with a live session")
                await bootPage()
            } else if bootSeconds >= Timing.clientServices {
                log.log(.client, "client services did not arrive in time — booting the page anyway")
                await bootPage()
            }
            return true
        }
    }

    /// Starts a boot phase and its clock.
    private func enterBoot(_ phase: BootPhase) {
        boot = phase
        bootBegan = .now
    }

    private func endBoot() {
        boot = .idle
        bootBegan = nil
    }

    private func reactToPage(wineWindows: [WineWindowWatch.Window]) async {
        switch await Self.probePage() {
        case .bridgeDown:
            endBoot()
            pageServicesUp = false
            fault = .degraded("bridge is down — relaunch Sevoflurane")
            transition(
                logging: .bridge,
                "in-process bridge on :\(BridgePorts.steamUI) is unreachable",
            )
        case let .notAnswering(detail):
            endBoot()
            pageServicesUp = false
            pageFailures += 1
            if pageFailures >= 2,
               Date.now.timeIntervalSince(lastPageRecovery) > Timing.servicesGrace {
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
        case .answering(servicesUp: false):
            endBoot()
            pageServicesUp = false
            await recoverDeadServices(wineWindows: wineWindows)
        case .answering(servicesUp: true):
            endBoot()
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
                if becameHealthy, showLibraryOnHealthy {
                    showLibraryOnHealthy = false
                    log.log(.supervisor, "sign-in finished — opening the library")
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
            if scan.gameWindowUp {
                GameDisplayHold.gameDidAppear()
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
        // slow until it has been mute for half a minute. This app's own log
        // holds three restarts whose only evidence was two 3-second `/json`
        // timeouts against a swapped-out CEF — each one a two-minute outage
        // the user paid for a probe's impatience.
        let processAlive = await ClientLifecycle.clientProcessAlive()
        // A DevTools server that accepted the connection and said nothing, on
        // a client whose transport is still open, is under load rather than
        // gone: the socket the bridge holds is the second opinion `/json`
        // alone cannot give.
        let clientSocketOpen = app.facts.isClientConnected
        let busyButConnected = client == .busy && clientSocketOpen
        let deadLongEnough = !busyButConnected && clientFailures >= 3
            && Date.now.timeIntervalSince(firstClientFailure) >= 30
        if !wineWindows.isEmpty, hasSeenClientUp {
            await restartClient(
                reason: reason + " with a Wine dialog up — Steam's own watchdog likely fired",
            )
        } else if !processAlive || deadLongEnough {
            let cause = if processAlive {
                reason + " for \(Int(Date.now.timeIntervalSince(firstClientFailure)))s"
            } else if hasSeenClientUp {
                "the client process is gone"
            } else {
                "starting the client"
            }
            await restartClient(reason: cause)
        } else if hasSeenClientUp {
            fault = .degraded(reason)
            transition(logging: .client, reason)
        }
    }

    /// The launch is still converging: CDP arrives at an arbitrary moment past
    /// ~15 s and a first-ever boot may show the updater for minutes, so the
    /// cycle reports progress rather than restarting into a client that is on
    /// its way. Every other failure path stays live throughout.
    private func advanceBootWait(wineWindows: [WineWindowWatch.Window]) {
        let waited = bootSeconds
        if waited >= Timing.clientBoot {
            endBoot()
            fault = .degraded("client did not come back within \(Timing.clientBoot)s of launch")
            transition(
                logging: .client,
                "client did not come back within \(Timing.clientBoot)s of launch",
            )
            return
        }
        // A Wine window with CDP still dead this far in is Steam saying
        // something instead of starting — the gptk-wine wedge sat in this
        // wait for its full length, three times over, before anything could
        // see it. Only once the session has had a working client: a
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
        progressPhase = "waiting for the client (\(waited)s)"
    }

    /// The page answers but Steam's stores never initialized. Boot and reload
    /// both need time to log in and fill the stores; past that, a reload is
    /// the cheap try, and a client whose UI session died (splash freeze,
    /// "Sign in to Steam") needs the full restart — a reload alone reattaches
    /// to the same dead session.
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

    private func recoverDeadServices(wineWindows: [WineWindowWatch.Window]) async {
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
            showLibraryOnHealthy = true
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
        guard Date.now.timeIntervalSince(lastPageRecovery) > Timing.servicesGrace else {
            // Not a fault: the page is up and Steam's stores are still
            // filling. Reporting it as degraded put an orange "Steam is
            // struggling" and a menu-bar dot in front of the user for the
            // whole grace, which is what a first run looks like from the
            // outside — the one thing `.launching` exists to prevent.
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
    private func transition(logging category: EventLog.Category, _ message: String) {
        let before = health
        refreshHealth()
        guard health != before else { return }
        log.log(category, message)
    }

    // MARK: - Restart ladder

    private func restartClient(reason: String, fullWindows: Bool = false) async {
        guard !isQuitting, !provisioningBlocksStart(reason: reason) else { return }
        if isRestarting {
            restartAgain = reason
            log.log(.supervisor, "restart requested mid-restart (\(reason)); the ladder runs again")
            return
        }
        isRestarting = true
        defer {
            isRestarting = false
            refreshHealth()
        }
        var reason = reason, fullWindows = fullWindows
        while true {
            await runRestartLadder(reason: reason, fullWindows: fullWindows)
            guard let again = restartAgain, !isQuitting else { return }
            restartAgain = nil
            reason = again
            fullWindows = false
        }
    }

    /// One pass of the ladder: stop what is up, launch under `Engine.active`
    /// as it is at launch time, wait for the client. A restart asked for on
    /// the way (`restartAgain`) ends the pass early, before the launch when
    /// it can, so the next pass decides afresh what has to come down.
    private func runRestartLadder(reason: String, fullWindows: Bool) async {
        let ladder = PerfProbe.supervisor.beginInterval("ClientRestart")
        defer { PerfProbe.supervisor.endInterval("ClientRestart", ladder) }

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            await escalateCrashLoop()
            return
        }
        let stamp = Date.now
        recentRestarts.append(stamp)
        pendingRestart = stamp
        clientFailures = 0
        clientShowsLoginWindow = false
        // A pass that will launch is a fresh try, so the last one's verdict —
        // a crash loop included — stops being the state to report.
        fault = nil
        log.log(.supervisor, "restarting client: \(reason)")

        // Take the dead client's frozen windows off screen now, rather than
        // leaving a dimmed, unresponsive library up for the whole teardown.
        await app.send(.dismissWindows)

        setRestartPhase("checking for a running client")
        // Windows stays booted through a plain client restart — the ~20s
        // machine boot is the biggest slice of a restart, and the resident
        // wineserver only has to go when the next launch actually needs a
        // different one: another engine's, or new sync primitives (esync/
        // msync are negotiated with the server at spawn).
        let windowsCanStay = !fullWindows
            && BottleGraphics.bootedEngineRoot() == Engine.active.root.path
            && BottleGraphics.bootedSelection()?.msync
            == BottleGraphics.currentSelection().msync
        if windowsCanStay {
            await ClientLifecycle.stopClient(gracePolls: 10) { phase in
                setRestartPhase(phase)
            }
        } else {
            await app.duringClientStop {
                await ClientLifecycle.stopAll(gracePolls: 10, hidingPopups: true) { phase in
                    setRestartPhase(phase)
                }
            }
        }

        // The launcher can time out and *still* spawn a client later; a
        // steam.exe that survived everything above means launching now could
        // stack a second instance on top of it. This guard plus
        // `isRestarting` is the entire double-start defense: restart
        // generation tags were considered and dropped because
        // `-nocrashdialog` removed Steam's own watchdog — the only other
        // writer that could race a relaunch. If a double-start ever appears
        // in the log again, tags are the next step.
        let leftovers = await ClientLifecycle.bottleProcessIDs(matching: "steam.exe")
        guard leftovers.isEmpty else {
            fault = .degraded("a steam.exe survived kill -9 — not launching a second client")
            transition(
                logging: .client,
                "steam.exe pids \(leftovers) survived SIGKILL — manual intervention needed",
            )
            return
        }
        guard !isQuitting else { return }
        // The engine may have changed under this pass; the next one settles
        // what has to come down for it before anything is launched.
        guard restartAgain == nil else { return }

        setRestartPhase("launching the client")
        log.log(.client, "launching the bottle client with CDP on :\(BridgePorts.cdp)")
        clientStartedAt = .now
        await ClientLifecycle.launchClient()
        // The ladder's work ends with the spawn. Everything the client does
        // next — CDP arriving, its services, its sign-in window, the page
        // booting — is a state of the probe cycle, which has the guards and
        // the cadence for it.
        enterBoot(.awaitingClient)
    }

    /// The rung the ladder is on, as the menu bar and the footer show it.
    private func setRestartPhase(_ phase: String) {
        restartPhase = phase
        refreshHealth()
    }

    /// Three restarts in ten minutes is the crash-loop signature; another
    /// plain restart would only stack crash dumps. The proven response is one
    /// hygiene pass — trash the Chromium cache, headless client repair — and
    /// a crash loop that survives *that* gets `gaveUp`: the machine needs a
    /// human.
    private func escalateCrashLoop() async {
        let hygiene = PerfProbe.supervisor.beginInterval("CrashLoopHygiene")
        defer { PerfProbe.supervisor.endInterval("CrashLoopHygiene", hygiene) }
        let dumps = ClientLifecycle.recentDumpCount()
        guard !hygieneTried else {
            fault = .gaveUp("client keeps dying — likely crash-looping; see the log")
            transition(
                logging: .supervisor,
                "giving up: still crash-looping after the hygiene pass "
                    + "(\(dumps) fresh dumps in 10 min) — manual repair needed",
            )
            return
        }
        hygieneTried = true
        log.log(
            .supervisor,
            "3 restarts in 10 minutes (\(dumps) fresh dumps) — crash loop; "
                + "running the hygiene pass: htmlcache purge + headless client repair",
        )
        setRestartPhase("crash loop: stopping the client")
        await app.duringClientStop {
            await ClientLifecycle.stopAll(gracePolls: 10) { phase in
                setRestartPhase(phase)
            }
        }
        guard !isQuitting else { return }
        if ClientLifecycle.purgeHTMLCache() {
            log.log(.client, "trashed the bottle's htmlcache")
        }
        setRestartPhase("crash loop: repairing the client (takes minutes)")
        let updated = await ClientLifecycle.headlessUpdate()
        log.log(
            .client,
            updated ? "headless client repair finished"
                : "headless client repair did not exit cleanly",
        )
        guard !isQuitting else { return }
        setRestartPhase("launching the client")
        clientStartedAt = .now
        await ClientLifecycle.launchClient()
        enterBoot(.awaitingClient)
    }

    // MARK: - Probes

    private enum PageState: Equatable {
        /// The page evals; `servicesUp` is whether Steam's stores finished
        /// initializing — the part that dies with the client's UI session.
        case answering(servicesUp: Bool)
        case bridgeDown
        case notAnswering(String)
    }

    /// One probe covers the whole chain the UI depends on: app page → bridge
    /// WebSocket → page eval and back. The bridge always answers HTTP 200 with
    /// `ok: false` carrying the failure ("no page connected", eval timeout),
    /// so an HTTP-level failure specifically means the bridge itself is down.
    ///
    /// The expression asks Steam's own app object whether its stores finished
    /// initializing. A bare eval is not enough: the page runs in the app's
    /// WKWebView and keeps answering evals after the client's UI session dies
    /// (steamwebhelper hang, regression to the login window) — a state where
    /// CDP still lists SharedJSContext and the user sees a frozen splash.
    private nonisolated static func probePage() async -> PageState {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/__eval")!)
        request.httpMethod = "POST"
        request.httpBody = Data(
            "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))".utf8,
        )
        request.timeoutInterval = 30
        guard let (data, _) = try? await URLSession.shared.data(for: request) else {
            return .bridgeDown
        }
        struct Reply: Decodable { let ok: Bool; let v: String? }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return .notAnswering("malformed /__eval reply")
        }
        guard reply.ok else { return .notAnswering(reply.v ?? "eval failed") }
        return .answering(servicesUp: reply.v?.contains("true") == true)
    }
}
