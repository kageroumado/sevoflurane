import AppKit
import Foundation
import Observation
import os

/// Keeps the bottled Steam client alive so the app survives it.
///
/// The client is healthy only when CDP answers *and* its target list contains
/// the `SharedJSContext` page — a listening port without that page is the
/// half-wedged client. On sustained failure the supervisor restarts the
/// client: graceful `-shutdown`, then `wineserver -k`, then signals, each rung
/// only for what the previous one left alive. A new client invalidates
/// CLIENT_SESSION and the transport ports, so recovery ends by reloading the
/// app's page — the bridge's 302 re-fetches both.
@MainActor
@Observable
final class ClientSupervisor {
    enum Health: Equatable {
        case starting
        case healthy
        /// Signed out with the login window up: Steam's services stay down
        /// until the user signs in, so recovery is held — the machine is
        /// waiting on a human, not wedged.
        case waitingForSignIn
        /// Something is failing; the reason is shown in the menu bar.
        case degraded(String)
        /// Mid-restart; the phase is shown in the menu bar.
        case restarting(String)
        /// A startup in progress. Wine takes tens of seconds to bring the
        /// client's CDP endpoint up and Steam's stores take longer still, and
        /// this app is on screen throughout — a launch that is merely slow
        /// must not read as a fault, and must not be "recovered" from.
        case launching(String)
        /// Repeated restarts failed — the client is crash-looping and another
        /// launch would only stack crash dumps. Manual restarts only.
        case gaveUp(String)
        case paused
    }

    private(set) var health: Health = .starting

    /// Whether the client has answered at all since the app started. Until it
    /// has, every failure is the first launch still happening.
    @ObservationIgnored private var hasSeenClientUp = false

    var statusText: String {
        switch health {
        case .starting: "checking the client…"
        case .healthy: "client healthy"
        case .waitingForSignIn: "waiting for sign-in"
        case let .degraded(reason): reason
        case let .restarting(phase): "restarting: \(phase)"
        case let .launching(phase): phase
        case let .gaveUp(reason): reason
        case .paused: "auto-restart paused"
        }
    }

    private let host: SteamWebHost
    /// Asked for its connection to the client before a page is booted into it.
    private let bridge: SteamBridge?
    private let log = EventLog.shared

    /// Whether the menu-bar glyph should carry the attention badge: the
    /// states where nothing is healing itself and the user should look.
    var needsAttention: Bool {
        switch health {
        case .degraded, .gaveUp: true
        default: false
        }
    }

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var clientFailures = 0
    @ObservationIgnored private var pageFailures = 0
    @ObservationIgnored private var isRestarting = false
    @ObservationIgnored private var recentRestarts: [Date] = []
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
    /// Dedupes the "Wine window visible" log line across probe cycles.
    @ObservationIgnored private var wineWindowsVisible = false
    /// Set once quit teardown begins; blocks every path that could relaunch
    /// the client mid-teardown.
    @ObservationIgnored private var isQuitting = false

    init(host: SteamWebHost, bridge: SteamBridge? = nil) {
        self.host = host
        self.bridge = bridge
    }

    #if DEBUG
        /// A supervisor that supervises nothing, fixed in one state — the
        /// gallery draws every state side by side and starts no client.
        convenience init(previewHealth: Health) {
            self.init(host: SteamWebHost())
            health = previewHealth
        }
    #endif

    func start() {
        guard loop == nil else { return }
        // The page the app just booted needs time to reach the bridge before
        // an unanswered probe means anything.
        lastPageRecovery = .now
        log.log(.supervisor, "supervision started (probing CDP :\(BridgePorts.cdp), bridge :\(BridgePorts.steamUI))")
        loop = Task(name: "Client supervision") { [weak self] in
            while !Task.isCancelled {
                await self?.probe()
                let interval: Duration = self?.health == .healthy ? .seconds(8) : .seconds(3)
                try? await Task.sleep(for: interval)
            }
        }
    }

    func togglePaused() {
        if health == .paused {
            health = .starting
            clientFailures = 0
            pageFailures = 0
            log.log(.supervisor, "auto-restart resumed")
        } else {
            health = .paused
            log.log(.supervisor, "auto-restart paused")
        }
    }

    /// Starts a game, restarting the client first when that game is pinned to
    /// a renderer the running session does not have.
    ///
    /// The renderer reaches a game through the environment of the process
    /// tree Steam already lives in, so there is no way to change it for one
    /// game without a new tree. The menu bar says so before the click; this
    /// is the click.
    func launch(_ game: SteamWebHost.RecentGame) async {
        guard let wanted = BottleGraphics.rendererNeedingRestart(forApp: game.id) else {
            host.launchGame(game)
            return
        }
        log.log(
            .client,
            "\(game.name) is pinned to \(wanted.label) — restarting the client for it",
        )
        do {
            try BottleGraphics.applyToActiveEngine(
                BottleGraphics.Selection(
                    renderer: wanted, msync: BottleGraphics.currentSelection().msync,
                ),
            )
        } catch {
            log.log(.client, "could not set \(wanted.label) for \(game.name): \(error)")
            host.launchGame(game)
            return
        }
        recentRestarts.removeAll()
        hygieneTried = false
        await restartClient(reason: "launching \(game.name) on \(wanted.label)")
        // The client is up and the page reloaded; Steam's own services need a
        // moment more before a launch request means anything.
        for _ in 0 ..< 40 where health != .healthy {
            try? await Task.sleep(for: .seconds(3))
        }
        host.launchGame(game)
    }

    /// The menu-bar button: restarts unconditionally, with a fresh crash-loop
    /// budget — the user asking is what distinguishes "try again" from a loop.
    func restartNow() {
        recentRestarts.removeAll()
        hygieneTried = false
        Task(name: "Manual client restart") {
            await restartClient(reason: "manual restart from the menu bar")
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
        if health != .paused {
            health = .paused
            log.log(.supervisor, "auto-restart paused (sevo client stop)")
        }
        await ClientLifecycle.stopAll(gracePolls: 15)
        log.log(.supervisor, "client stopped (sevo)")
    }

    /// `sevo client start`: resumes supervision, and restarts the client if
    /// it is not already up — the supervisor's ladder, not a bare launch.
    func startForControl() {
        if health == .paused {
            health = .starting
            clientFailures = 0
            pageFailures = 0
            log.log(.supervisor, "auto-restart resumed (sevo client start)")
        }
        Task(name: "sevo client start") {
            if await ClientLifecycle.probeClient() != .up {
                await restartClient(reason: "sevo client start")
            }
        }
    }

    /// Quit teardown: quitting Sevoflurane quits Steam. Stops supervision so
    /// nothing relaunches the client, then brings every bottle process down —
    /// the client's processes are launched detached, so without this they
    /// outlive the app (and a leaked webhelper window parks a dead icon in
    /// the Dock).
    func shutdownForQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        loop?.cancel()
        loop = nil
        log.log(.supervisor, "quit: bringing the bottle down")
        await ClientLifecycle.stopAll(gracePolls: 3)
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
        if health == .paused || isRestarting || isQuitting { return }
        let cycle = PerfProbe.supervisor.beginInterval("ProbeCycle")
        await probeChain()
        PerfProbe.supervisor.endInterval(
            "ProbeCycle", cycle, "\(self.statusText, privacy: .public)",
        )
    }

    private func probeChain() async {
        let wineWindows = observeWineWindows()

        let client = await ClientLifecycle.probeClient()
        guard client == .up else {
            await handleClientDown(client, wineWindows: wineWindows)
            return
        }
        clientFailures = 0
        hasSeenClientUp = true
        if case .gaveUp = health {
            log.log(.supervisor, "client recovered on its own")
        }

        // The client renders nothing here — a CEF window it opened for
        // itself (the first-run login window) is hidden as soon as it shows,
        // and the page's native mirror of the same popup is what the user
        // sees.
        let hiddenPopups = await ClientLifecycle.hideVisibleClientPopups()
        if !hiddenPopups.isEmpty {
            log.log(
                .client,
                "hid the client's own CEF window: \(hiddenPopups.joined(separator: ", ")) "
                    + "— the page renders these natively",
            )
        }

        switch await Self.probePage() {
        case .bridgeDown:
            transition(
                to: .degraded("bridge is down — relaunch Sevoflurane"),
                logging: .bridge,
                "in-process bridge on :\(BridgePorts.steamUI) is unreachable",
            )
        case let .notAnswering(detail):
            pageFailures += 1
            if pageFailures >= 2, Date.now.timeIntervalSince(lastPageRecovery) > 90 {
                log.log(.page, "page not answering with a healthy client (\(detail)) — reloading the UI")
                lastPageRecovery = .now
                pageFailures = 0
                host.reload()
                health = .degraded("reloading the UI…")
            } else {
                transition(
                    to: .degraded("page not answering (\(detail))"),
                    logging: .page,
                    "page not answering: \(detail)",
                )
            }
        case .answering(servicesUp: false):
            await recoverDeadServices(wineWindows: wineWindows)
        case .answering(servicesUp: true):
            pageFailures = 0
            serviceRecoveryTried = false
            hygieneTried = false
            wasAwaitingSignIn = false
            // steam.exe windows are VGUI dialogs (rescue/update/EULA) and
            // worth surfacing as a state; webhelper windows are leaked client
            // web UI (notification toasts) — logged on appearance, not a
            // health downgrade.
            if wineWindows.contains(where: { $0.owner.lowercased() == "steam.exe" }) {
                transition(
                    to: .degraded("Steam surfaced a dialog — see the log"),
                    logging: .supervisor,
                    "everything probes healthy but a steam.exe dialog is up — reporting, not acting",
                )
            } else {
                transition(
                    to: .healthy,
                    logging: .supervisor,
                    "healthy: client, bridge, page, and Steam services all up",
                )
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
    private func observeWineWindows() -> [WineWindowWatch.Window] {
        let wineWindows = WineWindowWatch.visibleWineWindows()
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
        let reason = client == .portWithoutContext
            ? "CDP is up but lists no SharedJSContext — half-wedged client"
            : "CDP unreachable — client down"
        clientFailures += 1
        if case .gaveUp = health { return }
        if clientFailures >= 2 || !wineWindows.isEmpty {
            await restartClient(reason: wineWindows.isEmpty ? reason
                : reason + " with a Wine dialog up — Steam's own watchdog likely fired")
        } else if hasSeenClientUp {
            transition(to: .degraded(reason), logging: .client, reason)
        } else {
            health = .launching("the client is coming up — a first launch takes a minute.")
        }
    }

    /// The page answers but Steam's stores never initialized. Boot and reload
    /// both need time to log in and fill the stores; past that, a reload is
    /// the cheap try, and a client whose UI session died (splash freeze,
    /// "Sign in to Steam") needs the full restart — a reload alone reattaches
    /// to the same dead session.
    private func recoverDeadServices(wineWindows: [WineWindowWatch.Window]) async {
        if host.isAwaitingSignIn {
            // A signed-out bottle's services never initialize until the user
            // signs in — the login window being up means the machine is
            // waiting on a human, not wedged. Holding the recovery clock
            // keeps the reload/restart ladder from tearing the login window
            // down mid-type, and gives services a fresh grace once sign-in
            // completes.
            wasAwaitingSignIn = true
            lastPageRecovery = .now
            serviceRecoveryTried = false
            transition(
                to: .waitingForSignIn,
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
            log.log(.page, "signed in — reloading the UI so the page boots with a session")
            lastPageRecovery = .now
            pageFailures = 0
            host.reload()
            health = .starting
            return
        }
        guard Date.now.timeIntervalSince(lastPageRecovery) > 90 else {
            // Not a fault: the page is up and Steam's stores are still
            // filling. Reporting it as degraded put an orange "Steam is
            // struggling" and a menu-bar dot in front of the user for the
            // whole grace, which is what a first run looks like from the
            // outside — the one thing `.launching` exists to prevent.
            transition(
                to: progress("waiting for Steam's services…"),
                logging: .page,
                "page up, Steam services not initialized yet",
            )
            return
        }
        if !wineWindows.isEmpty {
            // Services dead with a Wine dialog up is the known rescue-
            // dialog wedge (HANDOFF 02:16): the webhelper is gone, a
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
            host.reload()
            health = .degraded("reloading the UI…")
        }
    }

    private func transition(
        to newHealth: Health,
        logging category: EventLog.Category,
        _ message: String,
    ) {
        guard health != newHealth else { return }
        health = newHealth
        if newHealth == .healthy {
            PerfProbe.poi.emitEvent("Healthy")
        }
        log.log(category, message)
    }

    // MARK: - Restart ladder

    private func restartClient(reason: String) async {
        guard !isRestarting, !isQuitting else { return }
        isRestarting = true
        defer { isRestarting = false }
        let ladder = PerfProbe.supervisor.beginInterval("ClientRestart")
        defer { PerfProbe.supervisor.endInterval("ClientRestart", ladder) }

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            await escalateCrashLoop()
            return
        }
        recentRestarts.append(.now)
        clientFailures = 0
        log.log(.supervisor, "restarting client: \(reason)")

        health = .restarting("checking for a running client")
        await ClientLifecycle.stopAll(gracePolls: 15) { phase in
            health = .restarting(phase)
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
            transition(
                to: .degraded("a steam.exe survived kill -9 — not launching a second client"),
                logging: .client,
                "steam.exe pids \(leftovers) survived SIGKILL — manual intervention needed",
            )
            return
        }
        guard !isQuitting else { return }

        health = .restarting("launching the client")
        log.log(.client, "launching the bottle client with CDP on :\(BridgePorts.cdp)")
        await ClientLifecycle.launchClient()
        await awaitClientUp()
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
            transition(
                to: .gaveUp("client keeps dying — likely crash-looping; see the log"),
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
        health = .restarting("crash loop: stopping the client")
        await ClientLifecycle.stopAll(gracePolls: 15) { phase in
            health = .restarting(phase)
        }
        guard !isQuitting else { return }
        if ClientLifecycle.purgeHTMLCache() {
            log.log(.client, "trashed the bottle's htmlcache")
        }
        health = .restarting("crash loop: repairing the client (takes minutes)")
        let updated = await ClientLifecycle.headlessUpdate()
        log.log(
            .client,
            updated ? "headless client repair finished"
                : "headless client repair did not exit cleanly",
        )
        guard !isQuitting else { return }
        health = progress("launching the client")
        await ClientLifecycle.launchClient()
        await awaitClientUp()
    }

    /// The same phase, told as a first launch or as a recovery depending on
    /// whether this session has ever had a working client.
    private func progress(_ phase: String) -> Health {
        hasSeenClientUp ? .restarting(phase) : .launching(phase)
    }

    private func awaitClientUp() async {
        for waited in stride(from: 3, through: 180, by: 3) {
            health = progress("waiting for the client (\(waited)s)")
            try? await Task.sleep(for: .seconds(3))
            if await ClientLifecycle.probeClient() == .up {
                PerfProbe.poi.emitEvent("ClientBack", "up after ~\(waited)s")
                log.log(.client, "client is back — CDP + SharedJSContext up after ~\(waited)s")
                health = progress("connecting to the client")
                await bridge?.waitForClientConnection()
                health = progress("waiting for Steam's services…")
                let servicesReady = await bridge?.waitForClientServices() ?? false
                if servicesReady {
                    log.log(.client, "client services ready — booting the page with a live session")
                } else {
                    log.log(.client, "client services did not arrive in time — booting the page anyway")
                }
                lastPageRecovery = .now
                pageFailures = 0
                host.reload()
                health = .starting
                return
            }
        }
        transition(
            to: .degraded("client did not come back within 180s of launch"),
            logging: .client,
            "client did not come back within 180s of launch",
        )
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

    // MARK: - Wine tray suppression

    /// Ends the bottle's `explorer.exe`, the only process that can turn Steam's
    /// Windows tray icon into a macOS status item.
    ///
    /// Neither `ShowSystray` nor `NoTrayItemsDisplay` can stop it: decompiling
    /// CrossOver 26.3's explorer.exe shows `handle_incoming` forwarding every
    /// `NIM_ADD` to the display driver (`NtUserMessageCall … 0x306`) and
    /// returning before `show_icon`, which is where both registry gates are
    /// read. The driver then owns a real `NSStatusItem` we cannot reach. So the
    /// suppression is the process itself — the bottled client neither needs nor
    /// notices its absence (verified live: full CDP target list, working UI).
    ///
    /// Only called once the client is fully up: explorer also owns the desktop
    /// during startup, and killing it there stops the client from starting at
    /// all (measured — CDP never arrived within 180s). Skipped while a game is
    /// running for the same reason, untested there.
    private nonisolated static func suppressWineTray() async {
        guard await Subprocess.run("/usr/bin/pgrep", ["-f", "explorer.exe /desktop"]).status == 0 else {
            return
        }
        guard await !isGameRunning() else { return }
        let explorers = await ClientLifecycle.bottleProcessIDs(matching: "explorer.exe")
        guard !explorers.isEmpty else { return }
        for pid in explorers {
            kill(pid, SIGTERM)
        }
        await MainActor.run {
            EventLog.shared.log(
                .client,
                "suppressed the bottle's Wine tray host (explorer.exe \(explorers))",
            )
        }
    }

    /// True when a bottle process runs an executable that is not part of the
    /// client's own infrastructure — the cheap "a game is up" signal.
    private nonisolated static func isGameRunning() async -> Bool {
        let infrastructure: Set = [
            "steam.exe", "steamwebhelper.exe", "steamservice.exe", "explorer.exe",
            "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
            "rpcss.exe", "conhost.exe", "wineboot.exe", "start.exe", "rundll32.exe",
            "steamerrorreporter.exe", "steamerrorreporter64.exe", "tabtip.exe",
            "gameoverlayui64.exe", "cefwebhelper.exe",
        ]
        let out = await Subprocess.run("/usr/bin/pgrep", ["-af", "\\.exe"]).output
        for line in out.split(whereSeparator: \.isNewline) {
            guard let executable = line.split(separator: " ").first(where: {
                $0.lowercased().hasSuffix(".exe")
            }) else { continue }
            let name = String(executable.split(separator: "\\").last ?? executable).lowercased()
            if !infrastructure.contains(name) { return true }
        }
        return false
    }
}
