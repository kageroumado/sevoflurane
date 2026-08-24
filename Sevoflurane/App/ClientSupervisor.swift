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
@MainActor
@Observable
final class ClientSupervisor {
    /// The names the kill ladder owns. Mac Steam's own `ipcserver`
    /// (launchd `com.valvesoftware.steam.ipctool`) matches none of them.
    private nonisolated static let processNames = [
        "steam.exe",
        "steamwebhelper",
        "steamservice",
        "winedevice",
        "wineserver",
    ]

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
        case let .degraded(reason): reason
        case let .restarting(phase): "restarting: \(phase)"
        case let .gaveUp(reason): reason
        case .paused: "auto-restart paused"
        }
    }

    private let host: SteamWebHost
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
    /// Dedupes the "Wine window visible" log line across probe cycles.
    @ObservationIgnored private var wineWindowsVisible = false
    /// Set once quit teardown begins; blocks every path that could relaunch
    /// the client mid-teardown.
    @ObservationIgnored private var isQuitting = false

    init(host: SteamWebHost) {
        self.host = host
    }

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

    /// The menu-bar button: restarts unconditionally, with a fresh crash-loop
    /// budget — the user asking is what distinguishes "try again" from a loop.
    func restartNow() {
        recentRestarts.removeAll()
        Task(name: "Manual client restart") {
            await restartClient(reason: "manual restart from the menu bar")
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
        await stopBottleProcesses(gracePolls: 3) { _ in }
        let survivors = await Self.bottleProcessIDs()
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

        let wineWindows = observeWineWindows()

        let client = await Self.probeClient()
        guard client == .up else {
            await handleClientDown(client, wineWindows: wineWindows)
            return
        }
        clientFailures = 0
        if case .gaveUp = health {
            log.log(.supervisor, "client recovered on its own")
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
        _ client: ClientState,
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
        } else {
            transition(to: .degraded(reason), logging: .client, reason)
        }
    }

    /// The page answers but Steam's stores never initialized. Boot and reload
    /// both need time to log in and fill the stores; past that, a reload is
    /// the cheap try, and a client whose UI session died (splash freeze,
    /// "Sign in to Steam") needs the full restart — a reload alone reattaches
    /// to the same dead session.
    private func recoverDeadServices(wineWindows: [WineWindowWatch.Window]) async {
        guard Date.now.timeIntervalSince(lastPageRecovery) > 90 else {
            transition(
                to: .degraded("waiting for Steam services…"),
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
        log.log(category, message)
    }

    // MARK: - Restart ladder

    private func restartClient(reason: String) async {
        guard !isRestarting, !isQuitting else { return }
        isRestarting = true
        defer { isRestarting = false }

        recentRestarts.removeAll { $0.timeIntervalSinceNow < -600 }
        guard recentRestarts.count < 3 else {
            transition(
                to: .gaveUp("client keeps dying — likely crash-looping; see the log"),
                logging: .supervisor,
                "giving up after 3 restarts in 10 minutes — the client is crash-looping "
                    + "(next: clear the bottle's htmlcache, then a headless client update)",
            )
            return
        }
        recentRestarts.append(.now)
        clientFailures = 0
        log.log(.supervisor, "restarting client: \(reason)")

        health = .restarting("checking for a running client")
        await stopBottleProcesses(gracePolls: 15) { phase in
            health = .restarting(phase)
        }

        // The launcher can time out and *still* spawn a client later; a
        // steam.exe that survived everything above means launching now could
        // stack a second instance on top of it.
        let leftovers = await Self.bottleProcessIDs(matching: "steam.exe")
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
        await Self.launchClient()

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
        transition(
            to: .degraded("client did not come back within 180s of launch"),
            logging: .client,
            "client did not come back within 180s of launch",
        )
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

    private nonisolated static func probeClient() async -> ClientState {
        guard let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp) else {
            return .down
        }
        return targets.contains { $0["title"] as? String == "SharedJSContext" }
            ? .up : .portWithoutContext
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
        let explorers = await bottleProcessIDs(matching: "explorer.exe")
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

    // MARK: - Bottle processes

    /// Brings every bottle process down: graceful `-shutdown`, then
    /// `wineserver -k`, then signals, each rung only for what the previous
    /// one left alive. `gracePolls` bounds the graceful rung at 2 s per
    /// poll — a restart can afford 30 s of patience, quit cannot.
    private func stopBottleProcesses(
        gracePolls: Int,
        setPhase: (String) -> Void,
    ) async {
        let existing = await Self.bottleProcessIDs()
        guard !existing.isEmpty else { return }
        log.log(.client, "bottle processes running (pids \(existing)) — shutting them down")
        setPhase("stopping the client")
        await Self.gracefulShutdown()
        var clean = false
        for _ in 0 ..< gracePolls {
            if await Self.bottleProcessIDs().isEmpty { clean = true; break }
            try? await Task.sleep(for: .seconds(2))
        }
        if !clean {
            setPhase("force-killing wine")
            log.log(.client, "graceful shutdown timed out — wineserver -k")
            await Self.killWineserver()
            try? await Task.sleep(for: .seconds(3))
            var survivors = await Self.bottleProcessIDs()
            if !survivors.isEmpty {
                log.log(.client, "signalling survivors (pids \(survivors))")
                for pid in survivors {
                    kill(pid, SIGTERM)
                }
                try? await Task.sleep(for: .seconds(3))
                survivors = await Self.bottleProcessIDs()
                for pid in survivors {
                    kill(pid, SIGKILL)
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// PIDs of the bottle's processes, matched by name and then scoped by open
    /// files inside the bottle so other bottles' wine processes are untouched.
    private nonisolated static func bottleProcessIDs(matching name: String? = nil) async -> [pid_t] {
        var candidates: Set<pid_t> = []
        for processName in name.map({ [$0] }) ?? processNames {
            let out = await Subprocess.run("/usr/bin/pgrep", ["-if", processName]).output
            for token in out.split(whereSeparator: \.isNewline) {
                if let pid = pid_t(token.trimmingCharacters(in: .whitespaces)) {
                    candidates.insert(pid)
                }
            }
        }
        var scoped: [pid_t] = []
        for pid in candidates {
            let count = await Subprocess.run(
                "/bin/sh", ["-c", "lsof -p \(pid) 2>/dev/null | grep -c 'Bottles/\(SteamBottle.name)'"],
            ).output.trimmingCharacters(in: .whitespacesAndNewlines)
            if (Int(count) ?? 0) > 0 { scoped.append(pid) }
        }
        return scoped.sorted()
    }

    private nonisolated static func gracefulShutdown() async {
        _ = await Subprocess.run(
            SteamBottle.crossoverBin + "/wine",
            ["--bottle", SteamBottle.name, "--no-wait", SteamBottle.exeWindowsPath, "-shutdown"],
            capture: .none,
            timeout: .seconds(30),
        )
    }

    private nonisolated static func killWineserver() async {
        // CX_BOTTLE is not honored here; wineserver needs WINEPREFIX.
        _ = await Subprocess.run(
            SteamBottle.crossoverBin + "/wineserver",
            ["-k"],
            environment: ["WINEPREFIX": SteamBottle.root.path, "PATH": "/usr/bin"],
            capture: .none,
            timeout: .seconds(15),
        )
    }

    /// Fire and forget: the wine launcher regularly outlives its useful work
    /// by half a minute, so CDP polling — not the launcher exiting — decides
    /// whether the client is up. The exit is still logged for the trail.
    /// Nonisolated so the spawn never runs on the main thread.
    private nonisolated static func launchClient() async {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: SteamBottle.crossoverBin + "/wine")
        // -nocrashdialog suppresses steam.exe's VGUI rescue dialog
        // ("Steamwebhelper is not responding"); with it, the client relaunches
        // a wedged webhelper by itself instead of parking a visible Wine
        // window (Docs/resilience-spec.md experiment #1, verified 2026-08-22).
        process.arguments = [
            "--bottle",
            SteamBottle.name,
            "--no-wait",
            SteamBottle.exeWindowsPath,
            "-silent",
            "-nocrashdialog",
            "-cef-enable-debugging",
            "-devtools-port",
            String(BridgePorts.cdp),
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            EventLog.enqueue(.client, "wine launcher exited (status \(finished.terminationStatus))")
        }
        do {
            try process.run()
        } catch {
            EventLog.enqueue(
                .client,
                "wine launcher failed to start: \(error.localizedDescription)",
            )
        }
    }
}
