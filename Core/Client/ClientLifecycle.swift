import Foundation
import os
import Synchronization

/// The mechanics of the bottled client's life: probing, launching, and the
/// kill ladder. Policy lives with the callers (the daemon's
/// `BottleSupervisor`, the `sevo` CLI).
nonisolated enum ClientLifecycle {
    /// The names the kill ladder owns. Mac Steam's own `ipcserver`
    /// (launchd `com.valvesoftware.steam.ipctool`) matches none of them.
    static let processNames = [
        "steam.exe",
        "steamwebhelper",
        "steamservice",
        "winedevice",
        "wineserver",
    ]

    /// The client's own processes, which a client-only stop takes down while
    /// wineserver, services and device hosts stay resident.
    static let steamProcessNames = [
        "steam.exe",
        "steamwebhelper",
        "steamservice",
    ]

    /// Where lifecycle events go: the app points this at ``EventLog``, the
    /// CLI at stderr. Set once at process start, before any lifecycle call.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    /// Called with its status when the client's wine launcher exits, so the
    /// daemon hears of a death without waiting up to a minute for its poll.
    /// Same contract as ``log``.
    nonisolated(unsafe) static var clientDidExit: @Sendable (Int32) -> Void = { _ in }

    /// When this process last began a stop; an exit within ``stopWindow`` of
    /// it was asked for (the launcher's status 15, the Discord relay's 1).
    /// Locked because termination handlers read it off Foundation's threads.
    static var stopRequestedAt: Date? {
        get { stopRequest.withLock { $0 } }
        set { stopRequest.withLock { $0 = newValue } }
    }

    private static let stopRequest = Mutex<Date?>(nil)

    /// Long enough to cover a whole restart.
    static let stopWindow: TimeInterval = 300

    /// The log line for a program of ours that exited.
    static func exitLine(
        of name: String, status: Int32, stopRequestedAt: Date?, now: Date = .now,
    ) -> String {
        if let stopRequestedAt, now.timeIntervalSince(stopRequestedAt) < stopWindow {
            return "\(name) went down with the stop we asked for (status \(status))"
        }
        return "\(name) exited (status \(status))"
    }

    enum ClientState: Equatable {
        case up
        /// CDP answers but lists no `SharedJSContext` — the half-wedged client.
        case portWithoutContext
        /// The process is alive and its DevTools server accepted the
        /// connection without answering. A busy CEF under memory pressure
        /// reads like a dead one to a plain timeout, and restarting it costs
        /// two minutes for a stall that ends by itself.
        case busy
        case down
    }

    /// A generous timeout: a Rosetta CEF under memory pressure answers `/json`
    /// slowly, and a false "down" costs a two-minute full restart.
    static func probeClient() async -> ClientState {
        do {
            let targets = try await CDPClient.discoverTargets(
                port: BridgePorts.cdp, timeout: 10,
            )
            return targets.contains { $0["title"] as? String == "SharedJSContext" }
                ? .up : .portWithoutContext
        } catch {
            let unanswered = if case .unanswered = error as? CDPClient.Failure { true } else { false }
            if unanswered, await clientProcessAlive() { return .busy }
            return .down
        }
    }

    /// The switches every client launch carries.
    ///
    /// - `-nocrashdialog`: the client relaunches a wedged webhelper itself
    ///   instead of showing its VGUI "not responding" dialog.
    /// - `-disable-overlay-gpu-pri`: when the in-game overlay comes up, Steam
    ///   has its service raise the web helper's GPU priority through
    ///   `gdi32!D3DKMTSetProcessSchedulingPriorityClass`. Wine has no such
    ///   export, so `steamservice.exe` aborts, the engine thread waits on it
    ///   for good, and the overlay and every Steam call go dead.
    static let clientSwitches = [
        "-silent",
        "-nocrashdialog",
        "-disable-overlay-gpu-pri",
        "-cef-enable-debugging",
        "-devtools-port",
        String(BridgePorts.cdp),
    ]

    /// Whether a client process of these bottles exists at all, matched by
    /// this app's own launch line (`Steam.exe -silent`) and scoped like
    /// ``bottleProcessIDs(matchingAnyOf:in:)``. The probe's failure path uses
    /// it to separate "CDP is slow" from "nothing is running".
    static func clientProcessAlive(in targets: [BottleTarget] = BottleTarget.inScope) async -> Bool {
        await !clientProcessIDs(in: targets).isEmpty
    }

    /// The client's own processes in these bottles, matched by this app's
    /// launch line. The name alone also matches every `steamwebhelper.exe`,
    /// whose command line carries `-steampath=…\Steam.exe`.
    static func clientProcessIDs(in targets: [BottleTarget] = BottleTarget.inScope) async -> [pid_t] {
        let out = await Subprocess.run("/usr/bin/pgrep", ["-f", "Steam.exe -silent"]).output
        return await inBottle(processIDs(in: out), targets: targets)
    }

    // MARK: - Processes

    /// PIDs of the bottles' processes, matched by name and scoped to the
    /// bottles so other prefixes' wine processes are untouched.
    static func bottleProcessIDs(
        matching name: String? = nil, in targets: [BottleTarget] = BottleTarget.inScope,
    ) async -> [pid_t] {
        await bottleProcessIDs(matchingAnyOf: name.map { [$0] } ?? processNames, in: targets)
    }

    static func bottleProcessIDs(
        matchingAnyOf names: [String], in targets: [BottleTarget] = BottleTarget.inScope,
    ) async -> [pid_t] {
        var candidates: Set<pid_t> = []
        for processName in names {
            let out = await Subprocess.run("/usr/bin/pgrep", ["-if", processName]).output
            candidates.formUnion(processIDs(in: out))
        }
        return await inBottle(Array(candidates), targets: targets)
    }

    /// One pid per line, as `pgrep` prints them.
    private static func processIDs(in output: String) -> [pid_t] {
        output.split(whereSeparator: \.isNewline).compactMap {
            pid_t($0.trimmingCharacters(in: .whitespaces))
        }
    }

    /// The pids among `candidates` that belong to one of `targets`: by working
    /// directory (a prefix or its wineserver directory), else by open files
    /// through `libproc`. A program started from a folder outside the prefix
    /// shows neither; ``GameEnding`` knows it by its own path.
    private static func inBottle(_ candidates: [pid_t], targets: [BottleTarget]) async -> [pid_t] {
        guard !candidates.isEmpty, !targets.isEmpty else { return [] }
        let roots = bottleRoots(targets)
        let serverDirectories = Set(targets.compactMap { WineOrphans.serverDirectory(forPrefix: $0.path) })
        var scoped: [pid_t] = []
        var unsure: [pid_t] = []
        for pid in candidates {
            guard let directory = WineOrphans.workingDirectory(of: pid) else {
                unsure.append(pid)
                continue
            }
            if serverDirectories.contains(BottleIdentity.canonicalServerDirectory(directory))
                || isInBottle(openPaths: [directory], roots: roots) {
                scoped.append(pid)
            } else {
                unsure.append(pid)
            }
        }
        for pid in unsure where isInBottle(openPaths: WineOrphans.openFilePaths(of: pid), roots: roots) {
            scoped.append(pid)
        }
        return Set(scoped).sorted()
    }

    /// Each bottle's path, plain and link-resolved (as the kernel reports
    /// open files).
    private static func bottleRoots(_ targets: [BottleTarget]) -> [String] {
        Array(Set(targets.flatMap { [$0.prefix.path, $0.path] }))
    }

    /// Whether any of `paths` is a root or lies inside one; a sibling such as
    /// `Steam2` beside `Steam` is outside.
    static func isInBottle(openPaths paths: [String], roots: [String]) -> Bool {
        paths.contains { path in
            roots.contains { root in
                let directory = root.hasSuffix("/") ? String(root.dropLast()) : root
                return path == directory || path.hasPrefix(directory + "/")
            }
        }
    }

    /// What a force-quit reaches. `steam` takes the client down and leaves
    /// Windows booted; `everything` tears down the whole fake machine.
    enum ForceScope { case steam, everything }

    /// Immediate `SIGKILL` with no graceful ask, for when the ladder itself
    /// hung. Answers the processes it signaled.
    @discardableResult
    static func forceQuit(_ scope: ForceScope) async -> [pid_t] {
        let targets = BottleTarget.inScope
        let reach = BottleTarget.scopeNote(targets, configured: .configured)
        switch scope {
        case .steam:
            let pids = await bottleProcessIDs(matchingAnyOf: steamProcessNames, in: targets)
            for pid in pids { kill(pid, SIGKILL) }
            log("force-quit (\(reach)): SIGKILL'd \(pids.count) Steam process(es) \(pids)")
            return pids
        case .everything:
            // The sweep is for anything `wineserver -k` missed.
            await killWineservers(targets)
            let pids = await bottleProcessIDs(matchingAnyOf: processNames, in: targets)
            for pid in pids { kill(pid, SIGKILL) }
            log("force-quit (\(reach)): wineserver -k + SIGKILL'd \(pids.count) survivor(s) \(pids)")
            return pids
        }
    }

    /// The Windows program name behind each pid, best effort: a wine process
    /// carries its Windows exe as `argv` (`C:\…\Game.exe`).
    static func processNames(_ pids: [pid_t]) async -> [pid_t: String] {
        guard !pids.isEmpty else { return [:] }
        let out = await Subprocess.run(
            "/bin/ps", ["-o", "pid=,command=", "-p", pids.map(String.init).joined(separator: ",")],
        ).output
        var names: [pid_t: String] = [:]
        for line in out.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard let space = trimmed.firstIndex(of: " "),
                  let pid = pid_t(trimmed[..<space]) else { continue }
            let command = trimmed[trimmed.index(after: space)...]
            // "C:\Program Files (x86)\Steam\Steam.exe -silent" → "Steam.exe":
            // split on separators first, since the path holds spaces.
            let lastComponent = command
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? command
            names[pid] = lastComponent.split(separator: " ").first.map(String.init)
                ?? String(lastComponent)
        }
        return names
    }

    /// The most one DevTools call gets, less when its phase's deadline is
    /// nearer; it is the CDP budget's cap, since a call holds a permit.
    static let cdpCallCap = CDPBudget.callCap

    /// The smaller of a call's own cap and what remains of its phase.
    private static func cap(_ limit: Duration, until deadline: ContinuousClock.Instant) -> Duration {
        min(limit, ContinuousClock.now.duration(to: deadline))
    }

    /// Asks the clients of `targets` to exit; the CDP ask is bounded by
    /// `deadline`, the spawn fallback by its own timeout.
    static func gracefulShutdown(
        _ targets: [BottleTarget], until deadline: ContinuousClock.Instant,
    ) async {
        // StartShutdown in the client's own JS context first, and only when
        // the client answering the fixed CDP port belongs to one of these
        // bottles. `steam.exe -shutdown` spawns a second client instance to
        // deliver the message, so it is the fallback for a client whose CDP
        // is gone or answers for another bottle.
        var known: [String: String] = [:]
        for target in targets {
            if let directory = WineOrphans.serverDirectory(forPrefix: target.path) { known[directory] = target.path }
        }
        let owner = await BottleIdentity.clientPrefix(known: known)
        var asked: String?
        if let owner, targets.contains(where: { $0.path == owner }), await shutdownOverCDP(until: deadline) {
            asked = owner
        }
        for target in targets where target.path != asked {
            guard await clientProcessAlive(in: [target]) else { continue }
            let invocation = target.engine.wineInvocation(
                bottle: target.name, wait: .none,
                program: [SteamBottle.exeWindowsPath, "-shutdown"],
            )
            log("asking the client in bottle \(target.name) to shut down with steam.exe -shutdown")
            _ = await Subprocess.run(
                invocation.executable.path,
                invocation.arguments,
                environment: invocation.environment,
                capture: .none,
                timeout: .seconds(30),
            )
        }
    }

    /// `SteamClient.User.StartShutdown` in SharedJSContext; answers whether
    /// the ask was delivered.
    private static func shutdownOverCDP(until deadline: ContinuousClock.Instant) async -> Bool {
        guard let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp) else {
            return false
        }
        let script = """
        (function () {
          if (!window.SteamClient || !SteamClient.User
              || !SteamClient.User.StartShutdown) return "";
          SteamClient.User.StartShutdown(false);
          return "ok";
        })()
        """
        for target in targets where (target["title"] as? String) == "SharedJSContext" {
            guard let socketURL = (target["webSocketDebuggerUrl"] as? String).flatMap(URL.init)
            else { continue }
            let reply = try? await withDeadline(cap(cdpCallCap, until: deadline)) {
                try await CDPClient.evaluateOnce(socketURL: socketURL, script)
            }
            if reply == "ok" {
                log("client asked to shut down over CDP")
                return true
            }
        }
        return false
    }

    /// `wineserver -k` for each bottle, through the engine whose server holds it.
    static func killWineservers(_ targets: [BottleTarget]) async {
        for target in targets {
            // CX_BOTTLE is not honored here; wineserver needs WINEPREFIX.
            _ = await Subprocess.run(
                target.engine.wineserverURL.path,
                ["-k"],
                environment: ["WINEPREFIX": target.prefix.path, "PATH": "/usr/bin"],
                capture: .none,
                timeout: .seconds(15),
            )
        }
    }

    /// Stops Steam's own processes and leaves Windows booted, so the next
    /// client start skips the boot: a CDP shutdown ask, one-second polls for
    /// `gracePolls`, then SIGTERM and SIGKILL. Callers use
    /// ``stopAll(gracePolls:hidingPopups:phase:)`` instead for an engine or
    /// msync change, or a quit.
    static func stopClient(
        gracePolls: Int,
        targets: [BottleTarget] = BottleTarget.inScope,
        phase: (String) -> Void = { _ in },
    ) async {
        let reach = BottleTarget.scopeNote(targets, configured: .configured)
        let existing = await bottleProcessIDs(matchingAnyOf: steamProcessNames, in: targets)
        guard !existing.isEmpty else {
            log("client-only stop: no Steam process in \(reach) — nothing to stop")
            return
        }
        stopRequestedAt = .now
        log("stopping the client in \(reach) — Windows stays up (pids \(existing))")
        phase("stopping the client")
        let stopBegan = ContinuousClock.now
        let cdpDeadline = stopBegan + cdpBudget(gracePolls: gracePolls)
        if await clientProcessAlive(in: targets) {
            await gracefulShutdown(targets, until: cdpDeadline)
            for _ in 0 ..< gracePolls {
                _ = await hideVisibleClientPopups()
                if await bottleProcessIDs(matchingAnyOf: steamProcessNames, in: targets).isEmpty {
                    log("stop audit: client-only graceful exit in "
                        + "\(stopBegan.duration(to: .now).components.seconds)s")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        phase("force-quitting Steam")
        var survivors = await bottleProcessIDs(matchingAnyOf: steamProcessNames, in: targets)
        log("stop audit: client-only stop forcing after "
            + "\(stopBegan.duration(to: .now).components.seconds)s (pids \(survivors))")
        for pid in survivors {
            kill(pid, SIGTERM)
        }
        try? await Task.sleep(for: .seconds(2))
        survivors = await bottleProcessIDs(matchingAnyOf: steamProcessNames, in: targets)
        for pid in survivors {
            kill(pid, SIGKILL)
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// The shutdown ask's deadline: the call cap plus the grace in seconds.
    private static func cdpBudget(gracePolls: Int) -> Duration {
        cdpCallCap + .seconds(gracePolls)
    }

    /// Brings every process of `targets` down: the CDP shutdown ask while a
    /// client is alive, then `wineserver -k`, then signals, each rung only for
    /// survivors. `gracePolls` is the graceful rung's patience in one-second
    /// polls: a restart can afford 30, a quit cannot.
    static func stopAll(
        gracePolls: Int,
        targets: [BottleTarget] = BottleTarget.inScope,
        hidingPopups: Bool = false,
        phase: (String) -> Void = { _ in },
    ) async {
        let reach = BottleTarget.scopeNote(targets, configured: .configured)
        let existing = await bottleProcessIDs(in: targets)
        guard !existing.isEmpty else {
            log("stop: no process running in \(reach) — nothing to stop")
            return
        }
        stopRequestedAt = .now
        log("\(reach): processes running (pids \(existing)) — shutting them down")
        phase("stopping the client")
        // A shutdown ask only reaches a live client. When the client has
        // already crashed (the usual reason for a restart), the leftover
        // wineserver and winedevice never answer one, so the force rung
        // brings them down in seconds.
        let stopBegan = ContinuousClock.now
        let cdpDeadline = stopBegan + cdpBudget(gracePolls: gracePolls)
        var clean = false
        if await clientProcessAlive(in: targets) {
            await gracefulShutdown(targets, until: cdpDeadline)
            // A healthy client exits in 2–6 s.
            for _ in 0 ..< gracePolls {
                if hidingPopups {
                    // Hides the client's "Shutting down Steam…" dialog.
                    _ = await hideVisibleClientPopups()
                }
                if await bottleProcessIDs(in: targets).isEmpty { clean = true; break }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        if clean {
            log("stop audit: graceful exit in "
                + "\(stopBegan.duration(to: .now).components.seconds)s")
            return
        }
        phase("force-killing wine")
        log("stop audit: graceful shutdown timed out after "
            + "\(stopBegan.duration(to: .now).components.seconds)s — wineserver -k")
        await killWineservers(targets)
        try? await Task.sleep(for: .seconds(3))
        var survivors = await bottleProcessIDs(in: targets)
        if !survivors.isEmpty {
            log("signaling survivors (pids \(survivors))")
            for pid in survivors {
                kill(pid, SIGTERM)
            }
            try? await Task.sleep(for: .seconds(3))
            survivors = await bottleProcessIDs(in: targets)
            for pid in survivors {
                kill(pid, SIGKILL)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        log("stop audit: forced down in "
            + "\(stopBegan.duration(to: .now).components.seconds)s")
    }

    /// Extra `steam.exe` arguments from `SEVO_STEAM_ARGS`, whitespace
    /// separated: an experiment knob (`-nojoy`, `-noshaders`, `-cef-*`).
    static var extraClientArguments: [String] {
        (ProcessInfo.processInfo.environment["SEVO_STEAM_ARGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Fire and forget: the wine launcher regularly outlives its useful work
    /// by half a minute, so CDP polling decides whether the client is up and
    /// the launcher's exit is only logged. `@concurrent` so the spawn never
    /// runs on the calling actor.
    @concurrent
    static func launchClient() async {
        // The one place graphics choices take effect: the tree is staged
        // before steam.exe loads anything, so it is never crossed.
        if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
            log(note)
        }
        let process = Process()
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .none,
            program: [SteamBottle.exeWindowsPath] + clientSwitches
                + Engine.active.cefArguments + extraClientArguments,
        )
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = invocation.environment {
            process.environment = environment
        }
        let trail = WineLog.handle(labeled: "client") ?? FileHandle.nullDevice
        process.standardOutput = trail
        process.standardError = trail
        process.terminationHandler = { finished in
            log(exitLine(of: "wine launcher", status: finished.terminationStatus, stopRequestedAt: stopRequestedAt))
            try? trail.close()
            clientDidExit(finished.terminationStatus)
        }
        // Registered while the client is down: a running client rewrites
        // config.vdf.
        if Engine.active.supportsSteamPlayMacOS {
            for note in SteamPlayMacOS.prepareClient(steamRoot: SteamBottle.steamRoot, engineRoot: Engine.active.root) {
                log("Steam Play for macOS builds: \(note)")
            }
        }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        do {
            try process.run()
            // Games inherit this environment, so a later change owes a restart.
            BottleGraphics.recordBootedSelection()
            BootedBottle.record(.configured)
        } catch {
            log("wine launcher failed to start: \(error.localizedDescription)")
            closeTrail(trail)
        }
        // Records each game's executables after the spawn so the env files
        // and launcher bundles are in place before Steam starts a game.
        Task(name: "Record the library") {
            GameExecutables.recordLibrary()
            NWJSGames.recordLibrary()
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            await NWJSDefault.adoptLibrary { log($0) }
        }
        await startDiscordBridge()
    }

    /// Starts the Discord relay for this client boot. One bridge serves the
    /// prefix (a second copy exits on its mutex), and it comes down with the
    /// bottle.
    private static func startDiscordBridge() async {
        guard Preferences.discordBridge, let bridge = Engine.active.discordBridge else { return }
        await launchInBottle([bridge.path, "--dir", NSTemporaryDirectory()])
    }

    // MARK: - Client window suppression

    /// Hides the client's popups over the bridge's SharedJSContext connection
    /// (``SteamBridge/hideVisibleClientPopups()``); a process without a bridge
    /// sweeps nothing. Same contract as ``log``.
    nonisolated(unsafe) static var hidePopupsOverBridge:
        @Sendable (PopupSweepScope) async -> [String] = { _ in [] }

    /// Hides the client's visible CEF popups and answers their names. Every
    /// sweep goes through ``PopupSweeper`` so two never run at once.
    static func hideVisibleClientPopups(
        _ scope: PopupSweepScope = .everything,
    ) async -> [String] {
        let hide = PerfProbe.supervisor.beginInterval("PopupHide")
        defer { PerfProbe.supervisor.endInterval("PopupHide", hide) }
        return await PopupSweeper.shared.sweep(scope).names
    }

    /// Runs one of the app's standing scripts in the client's own friends UI,
    /// retrying until it answers one of `outcomes`, and answers that.
    ///
    /// The client runs a second copy of the UI this app hosts, which would
    /// open CEF chat windows and play the chime itself, so
    /// ``SteamChatAutoOpen`` and ``SteamMessageSound`` go to it too.
    static func installInClientUI(
        _ script: String, settledAt outcomes: Set<String>, attempts: Int = 10,
    ) async -> String {
        for attempt in 1 ... max(1, attempts) {
            if let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp),
               let shared = targets.first(where: { $0["title"] as? String == "SharedJSContext" }),
               let socketURL = (shared["webSocketDebuggerUrl"] as? String).flatMap(URL.init),
               let answer = try? await withDeadline(cdpCallCap, {
                   try await CDPClient.evaluateOnce(socketURL: socketURL, script)
               }),
               outcomes.contains(answer) {
                return answer
            }
            if attempt < attempts { try? await Task.sleep(for: .seconds(1)) }
        }
        return "the client's own friends UI never appeared"
    }

    /// Whether `App.GetServicesInitialized()` is true in SharedJSContext — the
    /// part that dies with the UI session while CDP still lists the target.
    /// Nil when the client cannot be reached.
    ///
    /// Asked over the connection the bridge already holds: a boot asks this
    /// once a second for two minutes, and a fresh DevTools session per ask has
    /// wedged the client twice. The default opens its own session for a
    /// process with no bridge, the `sevo` CLI. Same contract as ``log``.
    nonisolated(unsafe) static var servicesReadyOverBridge: @Sendable () async -> Bool? = {
        await servicesReadyOverOwnSession()
    }

    static func clientServicesReady() async -> Bool? {
        await servicesReadyOverBridge()
    }

    private static func servicesReadyOverOwnSession() async -> Bool? {
        guard let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp),
              let shared = targets.first(where: { $0["title"] as? String == "SharedJSContext" }),
              let socketURL = (shared["webSocketDebuggerUrl"] as? String).flatMap(URL.init)
        else { return nil }
        let answer = try? await withDeadline(.seconds(10)) {
            try await CDPClient.evaluateOnce(
                socketURL: socketURL,
                "String(!!(window.App&&App.GetServicesInitialized&&App.GetServicesInitialized()))",
            )
        }
        guard let answer else { return nil }
        return answer.contains("true")
    }

    // MARK: - Crash-loop hygiene

    /// Fresh `.dmp` files in the client's `dumps/` folder, by creation date;
    /// a climbing count while restarting is the crash-loop signature.
    static func recentDumpCount(within interval: TimeInterval = 600) -> Int {
        let cutoff = Date.now.addingTimeInterval(-interval)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: SteamBottle.dumps, includingPropertiesForKeys: [.creationDateKey],
        ) else { return 0 }
        return files.count { file in
            guard file.pathExtension.lowercased() == "dmp" else { return false }
            let date = try? file.resourceValues(forKeys: [.creationDateKey]).creationDate
            return date.map { $0 > cutoff } ?? false
        }
    }

    /// Whether a swept popup is the sign-in window
    /// (`SP DesktopLoginWindow_uid0`): a signed-out client, never a wedge.
    static func isLoginWindow(_ name: String) -> Bool {
        name.range(of: "DesktopLoginWindow", options: .caseInsensitive) != nil
    }

    /// Trashes the client's Chromium cache — the proven first response to a
    /// crash-looping webhelper. Only safe with the client stopped.
    @discardableResult
    static func purgeHTMLCache() -> Bool {
        (try? FileManager.default.trashItem(at: SteamBottle.htmlcache, resultingItemURL: nil)) != nil
    }

    /// Trashes ``SteamBottle/shaderCache`` (`steamapps/shadercache`) so the
    /// next launch rebuilds it. Only safe with the client stopped. Answers
    /// whether a cache was there.
    @discardableResult
    static func clearShaderCache() -> Bool {
        let cache = SteamBottle.shaderCache
        guard FileManager.default.fileExists(atPath: cache.path) else { return false }
        return (try? FileManager.default.trashItem(at: cache, resultingItemURL: nil)) != nil
    }

    /// Re-downloads the full client package and exits without logging in.
    /// Only safe with the client stopped.
    static func headlessUpdate() async -> Bool {
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .children,
            program: [
                SteamBottle.exeWindowsPath,
                "-forcesteamupdate", "-forcepackagedownload", "-exitsteam",
            ],
        )
        let result = await Subprocess.run(
            invocation.executable.path,
            invocation.arguments,
            environment: invocation.environment,
            capture: .none,
            timeout: .seconds(600),
        )
        return result.status == 0
    }

    // MARK: - Arbitrary programs

    /// Runs one Windows program in the Steam bottle to completion through the
    /// client's own engine invocation. A stop or restart of the client takes
    /// it down too.
    @discardableResult
    static func runInBottle(
        _ program: [String],
        timeout: Duration = .seconds(600),
    ) async -> (status: Int32?, output: String) {
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .children, program: program,
        )
        return await Subprocess.run(
            invocation.executable.path,
            invocation.arguments,
            environment: invocation.environment,
            capture: .combined,
            timeout: timeout,
        )
    }

    /// The same command, run by the daemon that owns the bottle whenever one
    /// answers, and in this process when none does.
    ///
    /// A dependency installer is a minutes-long wine tree, and the daemon
    /// outlives both the app window and the `sevo` process that asked for it.
    /// The direct fallback covers a machine with no daemon answering: the
    /// first run, before the app has registered one, and `--no-app`.
    ///
    /// Only an unreachable daemon, or one without `/bottle/run`, hands the
    /// program back: a request that broke off may have started it, and a
    /// second installer in the same bottle is worse than a failed run.
    @discardableResult
    static func runSupervisedInBottle(
        _ program: [String],
        timeout: Duration = .seconds(600),
    ) async -> (status: Int32?, output: String) {
        guard let request = daemonRunRequest(program, timeout: timeout) else {
            return await runInBottle(program, timeout: timeout)
        }
        switch await daemonRun(request) {
        case let .answered(result):
            return result
        case .unreachable:
            return await runInBottle(program, timeout: timeout)
        case let .failed(reason):
            log("bottle run through the daemon failed: \(reason)")
            return (nil, reason)
        }
    }

    /// What asking the daemon to run a program came to.
    enum DaemonRun {
        /// The daemon ran it and this is its result.
        case answered((status: Int32?, output: String))
        /// No daemon took the request, so nothing was started.
        case unreachable
        /// The daemon took the request, and whether the program started is
        /// unknown.
        case failed(String)
    }

    static func daemonRun(_ request: URLRequest, session: URLSession = .shared) async -> DaemonRun {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cannotConnectToHost {
            return .unreachable
        } catch {
            return .failed(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        // A daemon older than `/bottle/run` refuses the path before running anything.
        if status == 404 || status == 405 { return .unreachable }
        guard (200 ..< 300).contains(status), let result = daemonRunResult(data) else {
            return .failed("the daemon answered HTTP \(status)")
        }
        return .answered(result)
    }

    /// The `/bottle/run` request: one argument per body line, and a socket
    /// deadline past the program's own.
    static func daemonRunRequest(_ program: [String], timeout: Duration) -> URLRequest? {
        guard !program.isEmpty, !program.contains(where: { $0.contains("\n") }) else { return nil }
        let seconds = timeout.components.seconds
        guard let url = URL(
            string: "http://127.0.0.1:\(BridgePorts.control)/bottle/run?timeout=\(seconds)",
        ) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data(program.joined(separator: "\n").utf8)
        request.timeoutInterval = TimeInterval(seconds) + Self.daemonRunGrace
        ControlToken.authorize(&request)
        return request
    }

    /// How much longer than the bottle's own deadline the socket waits.
    private static let daemonRunGrace: TimeInterval = 30

    /// The daemon's answer: the program's exit status, absent where it was
    /// killed, and everything it printed.
    static func daemonRunResult(_ data: Data) -> (status: Int32?, output: String)? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = object["output"] as? String else { return nil }
        return ((object["status"] as? NSNumber).map(\.int32Value), output)
    }

    /// Starts one windowed Windows program in the Steam bottle and returns
    /// once it is spawned. `environment` replaces the invocation's own (for
    /// the companion prefix, ``SteamParent``).
    /// - Parameter programExit: For a launcher that exits with the program's
    ///   own code (the `steam.exe` parent), the program whose exit is written
    ///   to the Wine log (``ProgramExit``). Nil for `start /unix`, which
    ///   returns 0 at spawn.
    @concurrent
    static func launchInBottle(
        _ program: [String], environment: [String: String]? = nil, directory: URL? = nil,
        programExit: ProgramExit.Program? = nil,
    ) async {
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .none, program: program,
        )
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = environment ?? invocation.environment {
            process.environment = environment
        }
        if let directory {
            process.currentDirectoryURL = directory
        }
        // The name alone: a full path carries the account's name.
        let name = program.first.map(programName) ?? "?"
        let trail = WineLog.handle(labeled: name) ?? FileHandle.nullDevice
        process.standardOutput = trail
        process.standardError = trail
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            log(exitLine(of: name, status: status, stopRequestedAt: stopRequestedAt))
            // A signal's number is no exit code of the program's.
            if let programExit, finished.terminationReason == .exit {
                try? trail.write(contentsOf: Data((ProgramExit.line(programExit, status: status) + "\n").utf8))
            }
            try? trail.close()
        }
        do {
            try process.run()
        } catch {
            log("\(name) failed to start: \(error.localizedDescription)")
            closeTrail(trail)
        }
    }

    /// The last component of a Windows or Unix path.
    static func programName(of path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    /// Closes the log handle of a process that never started; the shared
    /// null device stays open.
    private static func closeTrail(_ trail: FileHandle) {
        guard trail !== FileHandle.nullDevice else { return }
        try? trail.close()
    }

    // MARK: - Update pinning

    /// Whether `steam.cfg` currently inhibits the client's self-updater.
    static func isPinned() -> Bool {
        ((try? String(contentsOf: SteamBottle.steamCfg, encoding: .utf8)) ?? "")
            .contains("BootStrapperInhibitAll=enable")
    }

    /// Pinning writes `steam.cfg` next to steam.exe to stop a client update
    /// that breaks under Wine. A pinned client eventually loses connectivity.
    static func setPinned(_ pinned: Bool) throws {
        if pinned {
            try Data("BootStrapperInhibitAll=enable\n".utf8).write(to: SteamBottle.steamCfg)
        } else if FileManager.default.fileExists(atPath: SteamBottle.steamCfg.path) {
            try FileManager.default.trashItem(at: SteamBottle.steamCfg, resultingItemURL: nil)
        }
    }
}
