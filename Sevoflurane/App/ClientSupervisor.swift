import AppKit
import Foundation
import Observation

/// Keeps the bottled Steam client alive so the app survives it.
///
/// The client is healthy only when CDP answers *and* its target list contains
/// the `SharedJSContext` page — a listening port without that page is the
/// half-wedged client. On sustained failure the supervisor restarts the
/// client: graceful `-shutdown`, then `wineserver -k`, then signals, each rung
/// only for what the previous one left alive. A new client invalidates
/// CLIENT_SESSION and the transport ports, so recovery ends by reloading the
/// app's page — the bridge's 302 re-fetches both.
private nonisolated enum Client {
    static let bottle = "Steam"
    static let cdpPort = 8081
    static let exe = #"C:\Program Files (x86)\Steam\Steam.exe"#
    static let wineBin = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"
    static let bottlePath = NSString(
        string: "~/Library/Application Support/CrossOver/Bottles/Steam").expandingTildeInPath
    /// The names the kill ladder owns. Mac Steam's own `ipcserver`
    /// (launchd `com.valvesoftware.steam.ipctool`) matches none of them.
    static let processNames = ["steam.exe", "steamwebhelper", "steamservice",
                               "winedevice", "wineserver"]
}

@MainActor
@Observable
final class ClientSupervisor {
    enum Health: Equatable {
        case starting
        case healthy
        /// Something is failing; the reason is shown in the menu bar.
        case degraded(String)
        /// Mid-restart; the phase is shown in the menu bar.
        case restarting(String)
        /// Repeated restarts failed — the client is crash-looping and another
        /// launch would only stack crash dumps. Manual restarts only.
        case gaveUp(String)
        case paused
    }

    private(set) var health: Health = .starting

    var statusText: String {
        switch health {
        case .starting: "checking the client…"
        case .healthy: "client healthy"
        case .degraded(let reason): reason
        case .restarting(let phase): "restarting: \(phase)"
        case .gaveUp(let reason): reason
        case .paused: "auto-restart paused"
        }
    }

    private let host: SteamWebHost
    private let log = EventLog.shared

    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var clientFailures = 0
    @ObservationIgnored private var pageFailures = 0
    @ObservationIgnored private var isRestarting = false
    @ObservationIgnored private var recentRestarts: [Date] = []
    @ObservationIgnored private var lastPageRecovery = Date.distantPast
    /// Whether the current services outage already got its one page reload —
    /// the next escalation is a client restart.
    @ObservationIgnored private var serviceRecoveryTried = false

    init(host: SteamWebHost) {
        self.host = host
    }

    func start() {
        guard loop == nil else { return }
        // The page the app just booted needs time to reach the bridge before
        // an unanswered probe means anything.
        lastPageRecovery = .now
        log.log(.supervisor, "supervision started (probing CDP :\(Client.cdpPort), bridge :8762)")
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

    /// The menu-bar button: restarts unconditionally, with a fresh crash-loop
    /// budget — the user asking is what distinguishes "try again" from a loop.
    func restartNow() {
        recentRestarts.removeAll()
        Task(name: "Manual client restart") {
            await restartClient(reason: "manual restart from the menu bar")
        }
    }

    // MARK: - Probe cycle

    private func probe() async {
        if health == .paused || isRestarting { return }

        let client = await Self.probeClient()
        guard client == .up else {
            let reason = client == .portWithoutContext
                ? "CDP is up but lists no SharedJSContext — half-wedged client"
                : "CDP unreachable — client down"
            clientFailures += 1
            if case .gaveUp = health { return }
            if clientFailures >= 2 {
                await restartClient(reason: reason)
            } else {
                transition(to: .degraded(reason), logging: .client, reason)
            }
            return
        }
        clientFailures = 0
        if case .gaveUp = health {
            log.log(.supervisor, "client recovered on its own")
        }

        switch await Self.probePage() {
        case .bridgeDown:
            transition(to: .degraded("bridge is down — start Spike/bridge.py"),
                       logging: .bridge, "bridge on :8762 is unreachable")
        case .notAnswering(let detail):
            pageFailures += 1
            if pageFailures >= 2, Date.now.timeIntervalSince(lastPageRecovery) > 90 {
                log.log(.page, "page not answering with a healthy client (\(detail)) — reloading the UI")
                lastPageRecovery = .now
                pageFailures = 0
                host.reload()
                health = .degraded("reloading the UI…")
            } else {
                transition(to: .degraded("page not answering (\(detail))"),
                           logging: .page, "page not answering: \(detail)")
            }
        case .answering(servicesUp: false):
            // Boot and reload both need time to log in and fill the stores;
            // past that, a reload is the cheap try, and a client whose UI
            // session died (splash freeze, "Sign in to Steam") needs the
            // full restart — a reload alone reattaches to the same dead
            // session.
            guard Date.now.timeIntervalSince(lastPageRecovery) > 90 else {
                transition(to: .degraded("waiting for Steam services…"),
                           logging: .page, "page up, Steam services not initialized yet")
                return
            }
            if serviceRecoveryTried {
                log.log(.client, "Steam services still down after a reload — "
                        + "the client's UI session is dead; restarting the client")
                await restartClient(reason: "client UI session dead (services never initialized)")
            } else {
                serviceRecoveryTried = true
                log.log(.page, "Steam services never initialized — reloading the UI")
                lastPageRecovery = .now
                host.reload()
                health = .degraded("reloading the UI…")
            }
        case .answering(servicesUp: true):
            pageFailures = 0
            serviceRecoveryTried = false
            transition(to: .healthy,
                       logging: .supervisor, "healthy: client, bridge, page, and Steam services all up")
        }
    }

    private func transition(to newHealth: Health,
                            logging category: EventLog.Category, _ message: String) {
        guard health != newHealth else { return }
        health = newHealth
        log.log(category, message)
    }

    // MARK: - Restart ladder

    private func restartClient(reason: String) async {
        guard !isRestarting else { return }
        isRestarting = true
        defer { isRestarting = false }

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            transition(to: .gaveUp("client keeps dying — likely crash-looping; see the log"),
                       logging: .supervisor,
                       "giving up after 3 restarts in 10 minutes — the client is crash-looping "
                       + "(next: clear the bottle's htmlcache, then lifecycle.py update)")
            return
        }
        recentRestarts.append(.now)
        clientFailures = 0
        log.log(.supervisor, "restarting client: \(reason)")

        health = .restarting("checking for a running client")
        let existing = await Self.bottleProcessIDs()
        if !existing.isEmpty {
            log.log(.client, "bottle processes running (pids \(existing)) — shutting them down")
            health = .restarting("stopping the client")
            await Self.gracefulShutdown()
            var clean = false
            for _ in 0..<15 {
                if await Self.bottleProcessIDs().isEmpty { clean = true; break }
                try? await Task.sleep(for: .seconds(2))
            }
            if !clean {
                health = .restarting("force-killing wine")
                log.log(.client, "graceful shutdown timed out — wineserver -k")
                await Self.killWineserver()
                try? await Task.sleep(for: .seconds(3))
                var survivors = await Self.bottleProcessIDs()
                if !survivors.isEmpty {
                    log.log(.client, "signalling survivors (pids \(survivors))")
                    for pid in survivors { kill(pid, SIGTERM) }
                    try? await Task.sleep(for: .seconds(3))
                    survivors = await Self.bottleProcessIDs()
                    for pid in survivors { kill(pid, SIGKILL) }
                    try? await Task.sleep(for: .seconds(1))
                }
            }
        }

        // The launcher can time out and *still* spawn a client later; a
        // steam.exe that survived everything above means launching now could
        // stack a second instance on top of it.
        let leftovers = await Self.bottleProcessIDs(matching: "steam.exe")
        guard leftovers.isEmpty else {
            transition(to: .degraded("a steam.exe survived kill -9 — not launching a second client"),
                       logging: .client,
                       "steam.exe pids \(leftovers) survived SIGKILL — manual intervention needed")
            return
        }

        health = .restarting("launching the client")
        log.log(.client, "launching the bottle client with CDP on :\(Client.cdpPort)")
        Self.launchClient()

        for waited in stride(from: 3, through: 180, by: 3) {
            health = .restarting("waiting for the client (\(waited)s)")
            try? await Task.sleep(for: .seconds(3))
            if await Self.probeClient() == .up {
                log.log(.client, "client is back — CDP + SharedJSContext up after ~\(waited)s")
                health = .restarting("reloading the UI")
                lastPageRecovery = .now
                pageFailures = 0
                host.reload()
                health = .starting
                return
            }
        }
        transition(to: .degraded("client did not come back within 180s of launch"),
                   logging: .client, "client did not come back within 180s of launch")
    }

    // MARK: - Probes

    private enum ClientState: Equatable { case up, portWithoutContext, down }
    private enum PageState: Equatable {
        /// The page evals; `servicesUp` is whether Steam's stores finished
        /// initializing — the part that dies with the client's UI session.
        case answering(servicesUp: Bool)
        case bridgeDown
        case notAnswering(String)
    }

    /// Wine binds the debug port to whichever loopback family it feels like on
    /// a given run, so the reachable one is discovered rather than assumed.
    private nonisolated static func probeClient() async -> ClientState {
        for hostName in ["127.0.0.1", "[::1]"] {
            var request = URLRequest(url: URL(string: "http://\(hostName):\(Client.cdpPort)/json")!)
            request.timeoutInterval = 3
            guard let (data, _) = try? await URLSession.shared.data(for: request) else { continue }
            struct Target: Decodable { let title: String }
            let targets = (try? JSONDecoder().decode([Target].self, from: data)) ?? []
            return targets.contains { $0.title == "SharedJSContext" } ? .up : .portWithoutContext
        }
        return .down
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
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8762/__eval")!)
        request.httpMethod = "POST"
        request.httpBody = Data(
            "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))".utf8)
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

    // MARK: - Bottle processes

    /// PIDs of the bottle's processes, matched by name and then scoped by open
    /// files inside the bottle so other bottles' wine processes are untouched.
    private nonisolated static func bottleProcessIDs(matching name: String? = nil) async -> [pid_t] {
        var candidates: Set<pid_t> = []
        for processName in name.map({ [$0] }) ?? Client.processNames {
            let out = await run("/usr/bin/pgrep", ["-if", processName]).output
            for token in out.split(whereSeparator: \.isNewline) {
                if let pid = pid_t(token.trimmingCharacters(in: .whitespaces)) {
                    candidates.insert(pid)
                }
            }
        }
        var scoped: [pid_t] = []
        for pid in candidates {
            let count = await run(
                "/bin/sh", ["-c", "lsof -p \(pid) 2>/dev/null | grep -c 'Bottles/\(Client.bottle)'"]
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if (Int(count) ?? 0) > 0 { scoped.append(pid) }
        }
        return scoped.sorted()
    }

    private nonisolated static func gracefulShutdown() async {
        _ = await run(Client.wineBin + "/wine",
                      ["--bottle", Client.bottle, "--no-wait", Client.exe, "-shutdown"],
                      captureOutput: false, timeout: .seconds(30))
    }

    private nonisolated static func killWineserver() async {
        // CX_BOTTLE is not honored here; wineserver needs WINEPREFIX.
        _ = await run(Client.wineBin + "/wineserver", ["-k"],
                      environment: ["WINEPREFIX": Client.bottlePath, "PATH": "/usr/bin"],
                      captureOutput: false, timeout: .seconds(15))
    }

    /// Fire and forget: the wine launcher regularly outlives its useful work
    /// by half a minute, so CDP polling — not the launcher exiting — decides
    /// whether the client is up. The exit is still logged for the trail.
    private static func launchClient() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: Client.wineBin + "/wine")
        process.arguments = ["--bottle", Client.bottle, "--no-wait", Client.exe,
                             "-silent", "-cef-enable-debugging",
                             "-devtools-port", String(Client.cdpPort)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    EventLog.shared.log(.client, "wine launcher exited (status \(status))")
                }
            }
        }
        do {
            try process.run()
        } catch {
            EventLog.shared.log(.client,
                                "wine launcher failed to start: \(error.localizedDescription)")
        }
    }

    /// Runs a subprocess to completion, killing it at the deadline. Output is
    /// captured only for the small query tools (pgrep, lsof); wine's chatter
    /// is not worth the pipe-buffer deadlock risk.
    private nonisolated static func run(
        _ path: String, _ arguments: [String],
        environment: [String: String]? = nil,
        captureOutput: Bool = true,
        timeout: Duration = .seconds(20)
    ) async -> (status: Int32?, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe: Pipe?
        if captureOutput {
            let captured = Pipe()
            pipe = captured
            process.standardOutput = captured
            process.standardError = FileHandle.nullDevice
        } else {
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        var watchdog: Task<Void, Never>?
        var launched = true
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            // The handler must be installed before run(): a process that exits
            // first never fires a handler installed after the fact.
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog = Task.detached {
                    try? await Task.sleep(for: timeout)
                    kill(pid, SIGKILL)
                }
            } catch {
                process.terminationHandler = nil
                launched = false
                continuation.resume()
            }
        }
        watchdog?.cancel()
        guard launched else { return (nil, "") }
        var output = ""
        if let pipe, let data = try? pipe.fileHandleForReading.readToEnd() {
            output = String(decoding: data, as: UTF8.self)
        }
        return (process.terminationStatus, output)
    }
}
