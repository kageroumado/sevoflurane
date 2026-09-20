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
        health.statusText
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
    @ObservationIgnored private var isQuitting = false

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
    @ObservationIgnored private var heldVerbs: [(path: String, verb: String)] = []

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
    /// rebuild that came back is followed by the hello an attach makes.
    func repairDaemon(force: Bool = false) async -> DaemonService.RepairResult {
        let result = await DaemonService.repair(force: force)
        if result == .reachable { await attach() }
        return result
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
        let verbs = heldVerbs
        heldVerbs = []
        for held in verbs { send(held.path, called: held.verb) }
    }

    /// Takes the verdict the daemon pushed. The app renders it and stores
    /// nothing else — there is one state machine and it is not here.
    func apply(_ snapshot: SupervisorSnapshot) {
        daemonIsUnreachable = false
        health = snapshot.supervisorHealth
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

    func togglePaused() {
        let path = health == .paused ? "/supervisor/resume" : "/supervisor/pause"
        Task(name: "Toggle auto-restart") {
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
        var path = "/game/launch?appid=\(game.id)&name=\(Self.escaped(game.name))"
        if let explicit { path += "&renderer=\(explicit.rawValue)" }
        guard await DaemonService.post(path, timeout: 300) != nil else {
            log.log(.client, "the daemon did not take the launch of \(game.name)")
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

    /// Puts Steam's window on screen as soon as the client is healthy. A
    /// person who opened the app came for that window, and the daemon is the
    /// one that knows when the client gets there.
    func showLibraryWhenHealthy() {
        send("/library/show-when-healthy", called: "show the library when healthy")
    }

    /// Quit teardown: quitting Sevoflurane quits Steam. The daemon holds the
    /// bottle, so the contract is one verb — and a crash, which sends nothing,
    /// is exactly why a crash leaves a running game alone.
    func shutdownForQuit() async {
        guard !isQuitting else { return }
        isQuitting = true
        facts?.cancel()
        facts = nil
        log.log(.supervisor, "quit: asking the daemon to bring the bottle down")
        _ = await DaemonService.post("/quit", timeout: 120)
        _ = await DaemonService.post("/app/detach")
    }

    /// Whether a provisioning failure is holding the client down: the last
    /// setup pass for this engine and bottle stopped at a stage that leaves
    /// nothing to start. Says so in the log once per attempt, because a client
    /// that never comes up is otherwise a mystery.
    func provisioningBlocksStart(reason: String) -> Bool {
        guard let failure = BottleReadiness.clientStartBlock else { return false }
        log.log(
            .supervisor,
            "not starting the client (\(reason)): the bottle is unfinished — \(failure)",
        )
        return true
    }

    private func send(_ path: String, called verb: String) {
        // A verb sent before the attach has settled reaches whichever daemon
        // is answering, and one of another build is about to be replaced: a
        // client it starts dies with it, half booted. The attach sends it.
        guard hasAttached else {
            heldVerbs.append((path, verb))
            return
        }
        Task(name: "Send \(verb) to the daemon") {
            guard await DaemonService.post(path, timeout: 120) != nil else {
                self.daemonIsUnreachable = true
                self.log.log(.supervisor, "the daemon did not take the \(verb)")
                return
            }
            await self.refreshFromDaemon()
        }
    }

    private enum Timing {
        /// Seconds of unanswered facts before the app says hello again.
        static let reattachAfterMissedFacts = 10
    }

    private nonisolated static func escaped(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
    }
}
