import Foundation
import Observation
import os

/// The app's view of supervision, which happens in `SevofluraneDaemon`.
///
/// The daemon owns every bottle process — that is what makes a force-quit or a
/// crash of this app survivable for a running game — so everything here is a
/// verb sent to the control port and a verdict pushed back from it. The app
/// keeps only what it alone can do: the page, Steam's popups, and the bridge.
///
/// There is deliberately no path that supervises from inside this process. A
/// daemon that cannot be registered or reached is a terminal state the user is
/// shown and asked to fix, because a fallback supervisor would be a second
/// owner of the bottle and the whole split exists to have one.
@MainActor
@Observable
final class ClientSupervisor {
    typealias Health = SupervisorHealth
    typealias Fault = SupervisorFault
    typealias HealthInputs = SupervisorHealthInputs

    /// Kept so the health rules have one test suite and one implementation
    /// whichever process derives them.
    nonisolated static func evaluateHealth(_ inputs: HealthInputs) -> Health {
        Health.evaluate(inputs)
    }

    private(set) var health: Health = .starting

    /// Told each time the client becomes healthy: signed in, its services
    /// up, ready for calls that change what it stores.
    @ObservationIgnored var onHealthy: (() -> Void)?

    /// Set while the daemon is unregistered, unapproved, or not answering. The
    /// menu bar shows the way out — Login Items, then Retry — rather than a
    /// state that looks like Steam's fault.
    private(set) var daemonIsUnreachable = false

    /// Whether the restart ladder is mid-flight, as the daemon last reported —
    /// control verbs that would race it refuse instead of interleaving.
    private(set) var isBusyRestarting = false
    /// What else weighs on this Mac, while it is more than ordinary: the
    /// daemon's reading, which is also what stretches its clocks.
    private(set) var hostPressure: HostPressure?

    var statusText: String {
        health.displayStatusText
    }

    var needsAttention: Bool {
        daemonIsUnreachable || health.needsAttention
    }

    private let host: SteamWebHost
    private let bridge: SteamBridge?
    private let log = EventLog.shared

    /// The facts last posted, so an unchanged second is not a second POST.
    @ObservationIgnored private var posted: PageFacts?
    @ObservationIgnored private var facts = Task<Void, Never>?.none
    /// Set from the moment the user confirms a quit. The popover shows the
    /// quit instead of the health the daemon reports while it tears the bottle
    /// down — a client nobody wants any more reads as paused there.
    private(set) var isQuitting = false
    @ObservationIgnored private var hasShutDown = false

    init(host: SteamWebHost, bridge: SteamBridge? = nil) {
        self.host = host
        self.bridge = bridge
    }

    #if DEBUG
        /// A supervisor bound to no daemon, fixed in one state — the gallery
        /// draws every state side by side and starts no client.
        convenience init(previewHealth: Health, hostPressure: HostPressure? = nil) {
            self.init(host: SteamWebHost())
            health = previewHealth
            self.hostPressure = hostPressure
        }
    #endif

    /// What the app saw that the daemon's probe cycle should not wait a tick
    /// to notice. The bridge learns of a dead client four seconds before the
    /// launcher exits, and a game window is the app's own observation.
    nonisolated enum Wake: Equatable, Sendable {
        case clientConnectionLost
        case gameWindowChanged
    }

    // MARK: - Attaching

    /// Whether the launch's attach has settled which daemon the app talks to.
    @ObservationIgnored private var hasAttached = false
    /// Verbs asked for before that, in order.
    @ObservationIgnored private var heldVerbs: [HeldVerb] = []

    /// A verb waiting for the attach. One the user clicked goes stale: a
    /// restart asked for while the daemon was waiting for approval in Login
    /// Items means nothing minutes later. The launch's own wish to show the
    /// library stays true however long the attach takes.
    nonisolated struct HeldVerb: Sendable {
        let path: String
        let verb: String
        let heldAt: ContinuousClock.Instant
        let expires: Bool
    }

    /// What the attach replays: each verb once, in the order its newest ask
    /// arrived, without the ones that went stale while it waited.
    nonisolated static func replayable(
        _ held: [HeldVerb], at now: ContinuousClock.Instant, staleAfter: Duration = .seconds(30),
    ) -> [HeldVerb] {
        held.enumerated()
            .filter { index, verb in !held[(index + 1)...].contains { $0.verb == verb.verb } }
            .map(\.element)
            .filter { !$0.expires || now - $0.heldAt < staleAfter }
    }

    func start() {
        let attachment = Task(name: "Attach to the daemon") { await self.attach() }
        facts = Task(name: "Post page facts") { [weak self] in
            await attachment.value
            var missed = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                await postFacts()
                // A daemon that stays silent is brought back by the attach —
                // it registers, rebuilds, or restarts as the silence warrants
                // — rather than by waiting for a human.
                missed = daemonIsUnreachable ? missed + 1 : 0
                if missed >= Timing.reattachAfterMissedFacts {
                    missed = 0
                    await attach()
                }
            }
        }
    }

    /// The user-driven rebuild of the daemon's registration, from `sevo daemon
    /// repair` and Settings › Recovery. A rebuild replaces the daemon process,
    /// and the new one knows nothing of this app until it is greeted, so a
    /// rebuild that came back is followed by the hello an attach makes, and
    /// the repair answers only once the new helper reports the app attached,
    /// or with the failure when it has not within
    /// ``DaemonHeal/repairAttachBudget`` seconds.
    func repairDaemon(force: Bool = false) async -> DaemonService.RepairResult {
        let result = await DaemonService.repair(force: force)
        guard result == .reachable else { return result }
        await attach()
        var saidHelloAgain = false
        var elapsed = 0
        while true {
            let seesApp = await DaemonService.status()?["app"] as? String == "running"
            switch DaemonHeal.repairAttach(
                daemonSeesApp: seesApp, elapsed: elapsed, saidHelloAgain: saidHelloAgain,
            ) {
            case .attached:
                return .reachable
            case .helloAgain:
                saidHelloAgain = true
                log.log(.supervisor, "the rebuilt helper has not taken the app yet — saying hello again")
                await attach()
            case .timedOut:
                log.log(
                    .supervisor,
                    "the rebuilt helper has not taken the app after \(elapsed)s — quit and reopen Sevoflurane",
                )
                return .failed(
                    "the background helper was rebuilt but has not attached to the app after "
                        + "\(elapsed)s — quit and reopen Sevoflurane",
                )
            case .wait:
                break
            }
            try? await Task.sleep(for: .seconds(1))
            elapsed += 1
        }
    }

    /// Brings the daemon up if it is not, then says hello. The registration is
    /// idempotent, so this is also the Retry the terminal state offers.
    func attach() async {
        let outcome = await DaemonService.ensureRunning()
        daemonIsUnreachable = !outcome.isReachable
        if daemonIsUnreachable {
            health = .gaveUp(outcome.message)
            log.log(.supervisor, "supervision is not running: \(outcome.message)")
            return
        }
        log.log(.supervisor, "attached to the supervision daemon on :\(BridgePorts.control)")
        posted = nil
        await postFacts()
        await refreshFromDaemon()
        hasAttached = true
        let verbs = Self.replayable(heldVerbs, at: .now)
        if verbs.count < heldVerbs.count {
            log.log(.supervisor, "dropped \(heldVerbs.count - verbs.count) stale or repeated verbs held for the attach")
        }
        heldVerbs = []
        for held in verbs { send(held.path, called: held.verb) }
    }

    /// Takes the verdict the daemon pushed. The app renders it and stores
    /// nothing else — there is one state machine and it is not here.
    func apply(_ snapshot: SupervisorSnapshot) {
        daemonIsUnreachable = false
        let wasHealthy = health == .healthy
        health = snapshot.supervisorHealth
        if !wasHealthy, health == .healthy { onHealthy?() }
        isBusyRestarting = snapshot.isBusyRestarting
        hostPressure = snapshot.host
    }

    /// Reads `/status` once. A push covers every change; this covers the two
    /// moments a push cannot — the attach, and a daemon that restarted while
    /// the app was mid-verb.
    private func refreshFromDaemon() async {
        guard let data = await DaemonService.get("/status"),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = object["health"] as? String else { return }
        apply(SupervisorSnapshot(
            health: name,
            detail: object["detail"] as? String ?? "",
            needsAttention: object["needsAttention"] as? Bool ?? false,
            host: (object["host"] as? [String: Any])
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
                .flatMap { try? JSONDecoder().decode(HostPressure.self, from: $0) },
        ))
    }

    /// Posts the facts, every tick. The post is the app's heartbeat as much as
    /// its news: the daemon answers `hello` for an app it had not seen, and a
    /// hello to an app that believed itself attached means the daemon was
    /// rebuilt or relaunched underneath it — a repair, or launchd bringing a
    /// crashed helper back — and knows nothing of this app's page. Its
    /// verdict is read again then, since the new daemon pushes nothing to an
    /// app it has only just met.
    private func postFacts() async {
        guard !isQuitting else { return }
        let current = await PageFacts(
            appPID: ProcessInfo.processInfo.processIdentifier,
            isAwaitingSignIn: host.isAwaitingSignIn,
            isClientConnected: bridge?.isClientConnected() ?? false,
            appVersion: Bundle.main
                .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0",
        )
        guard let body = try? JSONEncoder().encode(current),
              let reply = await DaemonService.post("/app/facts", body: body) else {
            daemonIsUnreachable = true
            return
        }
        daemonIsUnreachable = false
        let greetedAsNew = (try? JSONSerialization.jsonObject(with: reply) as? [String: Any])?["hello"]
            as? Bool ?? false
        let wasAttached = posted != nil
        posted = current
        if greetedAsNew, wasAttached {
            log.log(
                .supervisor,
                "the background helper was replaced under the app — attached to the new one",
            )
            await refreshFromDaemon()
        }
    }

    /// The daemon's probe cycle wakes on what this app saw. A wake is a hint,
    /// never a state: the cycle decides what it means.
    func wake(_: Wake) {
        Task(name: "Wake the daemon") { _ = await DaemonService.post("/supervisor/wake") }
    }

    // MARK: - Verbs

    /// Turns auto-restart on or off for the daemon's current run. Off, the
    /// supervisor stands aside entirely: it neither restarts nor starts Steam.
    func setAutoRestart(_ isOn: Bool) {
        let path = isOn ? "/supervisor/resume" : "/supervisor/pause"
        Task(name: "Set auto-restart") {
            _ = await DaemonService.post(path)
            await self.refreshFromDaemon()
        }
    }

    func restartNow(reason: String = "manual restart from the menu bar") {
        send("/client/restart?reason=\(Self.escaped(reason))", called: "restart")
    }

    func restartWindowsNow() {
        send("/client/restart?windows=1", called: "Windows restart")
    }

    func forceQuit(_ scope: ClientLifecycle.ForceScope) {
        send(
            "/client/forcequit?scope=\(scope == .everything ? "all" : "steam")",
            called: "force-quit",
        )
    }

    /// Starts a game, restarting the client first when that game is pinned to
    /// a renderer the running session does not have. The decision and the
    /// restart are the daemon's; the launch itself comes back here, because
    /// the call that starts a game is a line of JavaScript in the page.
    func launch(_ game: SteamWebHost.RecentGame, renderer explicit: Renderer? = nil) async {
        await launch(appID: game.id, name: game.name, renderer: explicit)
    }

    /// A game set to its macOS build goes to Steam for Mac instead
    /// (``MacBuildHandoff``); one started on a chosen renderer is a Windows
    /// launch whatever it is set to.
    func launch(appID: Int, name: String, renderer explicit: Renderer? = nil) async {
        if explicit != nil {
            MacBuildHandoff.allowWindowsLaunch(appID: appID)
        } else if MacBuildHandoff.take(appID: appID, name: name) {
            return
        }
        var path = "/game/launch?appid=\(appID)&name=\(Self.escaped(name))"
        if let explicit { path += "&renderer=\(explicit.rawValue)" }
        guard await DaemonService.post(path, timeout: 300) != nil else {
            log.log(.client, "the daemon did not take the launch of \(name)")
            return
        }
    }

    func stopForControl() async {
        _ = await DaemonService.post("/client/stop", timeout: 120)
    }

    /// Trashes Steam's shader cache and brings the client back — the daemon
    /// stops the bottle, clears the cache, and relaunches. Only
    /// `steamapps/shadercache` is removed; saves and game files stay.
    func clearShaderCache() {
        send("/bottle/clear-shader-cache", called: "clear the shader cache")
    }

    func startForControl() {
        send("/client/start", called: "start")
    }

    /// The stop before setup moves the choice to another bottle. A restart
    /// under way refuses a stop, so this waits for it to finish, narrating
    /// the wait, and asks again, for up to ``Timing/switchStopBudget``.
    /// Answers `nil` once no client is left running under the old choice,
    /// or why one still is, in which case the choice must not move.
    func stopBeforeBottleSwitch(narrate: (String) -> Void) async -> String? {
        let start = ContinuousClock.now
        while true {
            let answer = await Self.stopAnswer(DaemonService.postStatus("/client/stop", timeout: 120))
            let waited = ContinuousClock.now - start
            switch Self.switchStopStep(after: answer, waited: waited, budget: Timing.switchStopBudget) {
            case .proceed:
                return nil
            case .refuse:
                log.log(.supervisor, "setup: the client could not be stopped before the bottle switch (\(answer))")
                return answer == .busy
                    ? String(localized: "Steam is still restarting, so setup kept the bottle it had. Try again in a moment.")
                    : String(localized: "Steam could not be stopped, so setup kept the bottle it had. Try again, or quit Steam from the menu bar first.")
            case .waitForRestart:
                narrate("Waiting for Steam to finish restarting…")
                while ContinuousClock.now - start < Timing.switchStopBudget,
                      await DaemonService.status()?["health"] as? String == "restarting" {
                    try? await Task.sleep(for: .seconds(1))
                }
                narrate("Stopping Steam…")
            }
        }
    }

    /// How the daemon answered one `/client/stop`.
    nonisolated enum StopAnswer: Equatable, Sendable {
        case stopped
        /// 409: a restart ladder is running.
        case busy
        /// Any other refusal, or a stop that timed out on a daemon that
        /// still answers.
        case failed
        /// No daemon answers, so no client runs under it.
        case unreachable
    }

    nonisolated enum SwitchStopStep: Equatable, Sendable {
        case proceed
        case waitForRestart
        case refuse
    }

    /// What follows one answer to the stop before a bottle switch.
    nonisolated static func switchStopStep(
        after answer: StopAnswer, waited: Duration, budget: Duration,
    ) -> SwitchStopStep {
        switch answer {
        case .stopped, .unreachable: .proceed
        case .busy: waited < budget ? .waitForRestart : .refuse
        case .failed: .refuse
        }
    }

    private static func stopAnswer(_ status: Int?) async -> StopAnswer {
        switch status {
        case let status? where (200 ..< 300).contains(status): .stopped
        case 409: .busy
        case .some: .failed
        case nil: await DaemonService.isAnswering() ? .failed : .unreachable
        }
    }

    /// The start that ends setup. It outlasts an attach of any length,
    /// because the stop before a bottle switch paused supervision and only a
    /// start resumes it.
    func startAfterSetup() {
        send("/client/start", called: "start after setup", expires: false)
    }

    /// Puts Steam's window on screen as soon as the client is healthy. A
    /// person who opened the app came for that window, and the daemon is the
    /// one that knows when the client gets there.
    func showLibraryWhenHealthy() {
        send("/library/show-when-healthy", called: "show the library when healthy", expires: false)
    }

    /// Quit teardown: quitting Sevoflurane quits Steam. The daemon holds the
    /// bottle, so the contract is one verb — and a crash, which sends nothing,
    /// is exactly why a crash leaves a running game alone.
    /// Marks the quit as under way, before anything is torn down.
    func beginQuit() {
        isQuitting = true
    }

    func shutdownForQuit() async {
        guard !hasShutDown else { return }
        hasShutDown = true
        isQuitting = true
        facts?.cancel()
        facts = nil
        log.log(.supervisor, "quit: asking the daemon to bring the bottle down")
        _ = await DaemonService.post("/quit", timeout: 120)
        _ = await DaemonService.post("/app/detach")
    }

    private func send(_ path: String, called verb: String, expires: Bool = true) {
        // A verb sent before the attach has settled reaches whichever daemon
        // is answering, and one of another build is about to be replaced: a
        // client it starts dies with it, half booted. The attach sends it.
        guard hasAttached else {
            heldVerbs.append(HeldVerb(path: path, verb: verb, heldAt: .now, expires: expires))
            return
        }
        Task(name: "Send \(verb) to the daemon") {
            guard await DaemonService.post(path, timeout: 120) != nil else {
                self.daemonIsUnreachable = true
                if expires {
                    self.log.log(.supervisor, "the daemon did not answer \(verb); dropped")
                } else {
                    // The launch's own wish outlives a daemon that went away: the reattach
                    // replays it.
                    self.heldVerbs.append(HeldVerb(path: path, verb: verb, heldAt: .now, expires: false))
                    self.log.log(.supervisor, "the daemon did not answer \(verb); held for the reattach")
                }
                return
            }
            await self.refreshFromDaemon()
        }
    }

    private enum Timing {
        /// Seconds of unanswered facts before the app says hello again.
        static let reattachAfterMissedFacts = 10
        /// How long setup waits for a restart to finish before a bottle
        /// switch gives up.
        static let switchStopBudget: Duration = .seconds(60)
    }

    private nonisolated static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
