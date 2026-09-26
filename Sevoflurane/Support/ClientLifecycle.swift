import Foundation
import os
import Synchronization

/// The mechanics of the bottled client's life: probing, launching, and the
/// kill ladder. Policy lives with the callers — the daemon's
/// `BottleSupervisor` decides *when* to act, the `sevo` CLI exposes the same
/// actions to a terminal or an agent — so both drive one implementation.
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

    /// The client's own processes — what a client-only stop takes down,
    /// leaving the booted Windows (wineserver, services, device hosts)
    /// resident the way CrossOver keeps its fake machine warm.
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

    /// Called with its status when the wine launcher that spawned the client
    /// exits. The daemon points this at its `BottleSupervisor` so a death is
    /// an event rather than something the next poll happens to notice, and
    /// with a game up the poll is a minute apart. Same contract as ``log``.
    nonisolated(unsafe) static var clientDidExit: @Sendable (Int32) -> Void = { _ in }

    /// When this process last began bringing the bottle's programs down. What exits within
    /// ``stopWindow`` of it was asked to: the launcher by SIGTERM (status 15), the Discord
    /// relay by losing its wineserver (status 1). Read from termination handlers on
    /// Foundation's own threads, so it is kept under a lock.
    static var stopRequestedAt: Date? {
        get { stopRequest.withLock { $0 } }
        set { stopRequest.withLock { $0 = newValue } }
    }

    private static let stopRequest = Mutex<Date?>(nil)

    /// Long enough to cover a whole restart, so the launcher's exit at its end
    /// still reads as asked for.
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
        /// reads exactly like a dead one to a plain timeout, and treating the
        /// two alike bought a two-minute restart for a stall that ends by
        /// itself.
        case busy
        case down
    }

    /// A generous timeout: under memory pressure a Rosetta CEF answers
    /// `/json` slowly, and a slow answer must read as "slow", never as
    /// "down" — a false "down" costs a two-minute full restart.
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

    /// Whether a client process of these bottles exists at all, told by
    /// command line (`Steam.exe -silent` is this app's own launch line; the
    /// Mac Steam client is `steam_osx` and cannot match) and scoped like
    /// ``bottleProcessIDs(matchingAnyOf:in:)``. It runs on the probe's
    /// failure path to separate "CDP is slow" from "nothing is running", and
    /// the client's working directory is inside the prefix, so the answer
    /// is one `pgrep` and a kernel call.
    static func clientProcessAlive(in targets: [BottleTarget] = BottleTarget.inScope) async -> Bool {
        let out = await Subprocess.run("/usr/bin/pgrep", ["-f", "Steam.exe -silent"]).output
        return await !inBottle(processIDs(in: out), targets: targets).isEmpty
    }

    // MARK: - Processes

    /// PIDs of the bottles' processes, matched by name and then scoped by
    /// open files inside the bottles so other prefixes' wine processes are
    /// untouched. The default reach is the booted and the configured bottle.
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

    /// The pids among `candidates` that belong to one of `targets`.
    ///
    /// A process whose working directory lies in a prefix, or is a prefix's
    /// wineserver directory, is decided without spawning anything. The rest
    /// (a game working in a library folder outside the prefix, or a process
    /// between directories) are read in one `lsof` over all of them: the
    /// wineserver keeps the prefix itself open, and every other Wine process
    /// has a file inside it.
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
        if !unsure.isEmpty {
            let out = await Subprocess.run(
                "/usr/sbin/lsof", ["-w", "-Fn", "-p", unsure.map(String.init).joined(separator: ",")],
                timeout: .seconds(20),
            ).output
            for (pid, paths) in openPaths(inLsofFields: out) where isInBottle(openPaths: paths, roots: roots) {
                scoped.append(pid)
            }
        }
        return Set(scoped).sorted()
    }

    /// Each bottle's directory as a path and, where it differs, as the path
    /// with its links resolved, which is how the kernel reports open files.
    private static func bottleRoots(_ targets: [BottleTarget]) -> [String] {
        Array(Set(targets.flatMap { [$0.prefix.path, $0.path] }))
    }

    /// Whether any of `paths` is `roots`' directory itself or lies inside it.
    /// A sibling that merely begins with the same name (`Steam2` beside
    /// `Steam`) and another app's `Bottles/Steam` are elsewhere.
    static func isInBottle(openPaths paths: [String], roots: [String]) -> Bool {
        paths.contains { path in
            roots.contains { root in
                let directory = root.hasSuffix("/") ? String(root.dropLast()) : root
                return path == directory || path.hasPrefix(directory + "/")
            }
        }
    }

    /// The names `lsof -Fn` lists per process: a `p<pid>` line opens a
    /// process and each `n<name>` line after it is one of its files.
    static func openPaths(inLsofFields output: String) -> [pid_t: [String]] {
        var paths: [pid_t: [String]] = [:]
        var current: pid_t?
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": current = pid_t(value)
            case "n": if let current { paths[current, default: []].append(value) }
            default: continue
            }
        }
        return paths
    }

    /// What a force-quit reaches. `steam` takes the client down and leaves
    /// Windows booted; `everything` tears down the whole fake machine.
    enum ForceScope { case steam, everything }

    /// The escape hatch: immediate `SIGKILL`, no graceful ask and no wait —
    /// for when the graceful ladder is the thing that hung. Scoped by open
    /// files to the booted and the configured bottle, so another prefix's
    /// wine is never touched. Answers the processes it signaled.
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
            // wineserver -k brings down every process in the prefix — games
            // and service hosts included; the sweep is for anything it missed.
            await killWineservers(targets)
            let pids = await bottleProcessIDs(matchingAnyOf: processNames, in: targets)
            for pid in pids { kill(pid, SIGKILL) }
            log("force-quit (\(reach)): wineserver -k + SIGKILL'd \(pids.count) survivor(s) \(pids)")
            return pids
        }
    }

    /// The Windows program name behind each pid, best effort — so a
    /// force-quit's reply can name what it killed and what came back, not
    /// just count them. A wine process carries its Windows exe as `argv`
    /// (`C:\…\Game.exe`); the name is that path's last component.
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
            // "C:\Program Files (x86)\Steam\Steam.exe -silent" → "Steam.exe": the
            // path holds spaces, so split on the separators first, then drop
            // the arguments that trail the last component.
            let lastComponent = command
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? command
            names[pid] = lastComponent.split(separator: " ").first.map(String.init)
                ?? String(lastComponent)
        }
        return names
    }

    /// One DevTools call — a shutdown ask, a script install — gets at most
    /// this long, and less when its phase's deadline is nearer. The cap is
    /// the CDP budget's, because a call that holds a permit for longer holds
    /// it against everything else that wants to talk to the client.
    static let cdpCallCap = CDPBudget.callCap

    /// The smaller of a call's own cap and what remains of its phase.
    private static func cap(_ limit: Duration, until deadline: ContinuousClock.Instant) -> Duration {
        min(limit, ContinuousClock.now.duration(to: deadline))
    }

    /// Asks the clients of `targets` to exit. The CDP ask is bounded by
    /// `deadline`; the spawn fallback carries its own subprocess timeout.
    static func gracefulShutdown(
        _ targets: [BottleTarget], until deadline: ContinuousClock.Instant,
    ) async {
        // The quiet path first: StartShutdown in the client's own JS context,
        // and only when the client answering the port is one of these: CDP is
        // one fixed port, and a client of another bottle holding it would be
        // the one asked. `steam.exe -shutdown` spawns a whole second client
        // instance just to deliver the message — seconds of bottle work to
        // say one word. The spawn is the fallback for a client whose CDP is
        // gone or answers for another bottle, and it goes through the same
        // suppressed environment as every other spawn.
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

    /// Asks the running client to exit via `SteamClient.User.StartShutdown`
    /// in SharedJSContext. Answers whether the ask was delivered.
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

    /// Stops Steam's own processes and leaves Windows booted: a CDP shutdown
    /// ask, one-second polls for `gracePolls`, then SIGTERM and SIGKILL.
    ///
    /// Wineserver, services and the device hosts stay resident, so the next
    /// client start skips the machine boot entirely. The callers decide when
    /// Windows itself must go instead (``stopAll(gracePolls:hidingPopups:phase:)``):
    /// a different engine's wineserver, an msync change (sync primitives are
    /// negotiated with the server), a quit. A client that is already gone
    /// leaves nothing to wait for, so its leftovers go straight to the signals.
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

    /// The shutdown ask draws on one absolute deadline: the ask's cap plus
    /// the grace in seconds. A mute target can hold the ladder for at most
    /// this long; the force rung's subprocesses carry their own timeouts.
    private static func cdpBudget(gracePolls: Int) -> Duration {
        cdpCallCap + .seconds(gracePolls)
    }

    /// Brings every process of `targets` down: the CDP shutdown ask while a
    /// client is alive, then `wineserver -k`, then signals, each rung only for
    /// what the previous one left alive. `gracePolls` is the graceful rung's
    /// patience in one-second polls: a restart can afford 30 s, a quit cannot.
    /// The default reach is the booted and the configured bottle.
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
        // `steam.exe -shutdown` only means anything to a live client. When the
        // client has already crashed (the usual reason for a restart), asking
        // a corpse to shut down and then waiting 30 s for it is pure stall —
        // the leftover wineserver/winedevice never answer a client shutdown.
        // Skip straight to the force rung, which brings them down in seconds.
        let stopBegan = ContinuousClock.now
        let cdpDeadline = stopBegan + cdpBudget(gracePolls: gracePolls)
        var clean = false
        if await clientProcessAlive(in: targets) {
            await gracefulShutdown(targets, until: cdpDeadline)
            // One-second polls: a healthy client exits in 2–6 s, and a quit
            // with nothing to upload should be over in ten — the poll count
            // is the whole grace budget in seconds.
            for _ in 0 ..< gracePolls {
                if hidingPopups {
                    // The client shows its "Shutting down Steam…" dialog on
                    // the way out; hiding it each poll keeps a deliberate
                    // stop (an engine switch, `sevo client stop`) from
                    // narrating itself in Wine windows. It is optional: once
                    // the CDP budget is spent, the sweep does nothing.
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

    /// Extra `steam.exe` arguments from `SEVO_STEAM_ARGS` in the app's
    /// environment, whitespace-separated — an experiment knob (`-nojoy`,
    /// `-noshaders`, `-cef-*`) that reaches the client through the
    /// supervisor's own launch path.
    static var extraClientArguments: [String] {
        (ProcessInfo.processInfo.environment["SEVO_STEAM_ARGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    /// Fire and forget: the wine launcher regularly outlives its useful work
    /// by half a minute, so CDP polling — not the launcher exiting — decides
    /// whether the client is up. The exit is still logged for the trail.
    /// `@concurrent` so the spawn never runs on the calling actor.
    @concurrent
    static func launchClient() async {
        // Reconcile the engine tree to the desired selection before steam.exe
        // loads anything: the renderer DLLs and both halves of the picked
        // D3DMetal version, staged together. This is the single point graphics
        // effects happen, so a record-only picker takes effect at the next
        // spawn with no chance of a crossed tree.
        if let note = BottleGraphics.stagingNote(BottleGraphics.reconcileManagedTree()) {
            log(note)
        }
        let process = Process()
        // -nocrashdialog suppresses steam.exe's VGUI rescue dialog
        // ("Steamwebhelper is not responding"); with it, the client relaunches
        // a wedged webhelper by itself instead of parking a visible Wine
        // window.
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .none,
            program: [
                SteamBottle.exeWindowsPath,
                "-silent",
                "-nocrashdialog",
                "-cef-enable-debugging",
                "-devtools-port",
                String(BridgePorts.cdp),
            ] + Engine.active.cefArguments + extraClientArguments,
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
        // The per-bottle and per-program env files the engine reads at
        // every process start, from the store as it stands now.
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        do {
            try process.run()
            // Games inherit this environment; remember what it was so a
            // later selection change knows a restart is owed.
            BottleGraphics.recordBootedSelection()
            // And the bottle, which every stop reaches until the next spawn.
            BootedBottle.record(.configured)
        } catch {
            log("wine launcher failed to start: \(error.localizedDescription)")
            closeTrail(trail)
        }
        // What each installed game is built on and which executables it
        // ships, recorded for the library once per client start: a directory
        // listing per game and one loader scan for the NW.js ones, which is
        // why it follows the spawn rather than delaying it. The env files and
        // launcher bundles are then in place before Steam starts anything,
        // rather than a game's first run being an anonymous `wine`.
        Task(name: "Record the library") {
            GameExecutables.recordLibrary()
            NWJSGames.recordLibrary()
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        }
        await startDiscordBridge()
    }

    /// Starts the Discord relay for this client boot, so a game that ships its
    /// own Discord support finds the pipe already served when it looks.
    ///
    /// One bridge serves the whole prefix and a second copy exits on its own
    /// mutex, so starting it once per client boot is enough. It makes itself a
    /// Wine system process half a minute in and comes down with the bottle.
    private static func startDiscordBridge() async {
        guard Preferences.discordBridge, let bridge = Engine.active.discordBridge else { return }
        await launchInBottle([bridge.path, "--dir", NSTemporaryDirectory()])
    }

    // MARK: - Client window suppression

    /// What hides the client's popups: one evaluate on the SharedJSContext
    /// connection the bridge already holds
    /// (``SteamBridge/hideVisibleClientPopups()``). The app points this
    /// there; a process without a bridge — the `sevo` CLI — has no
    /// connection to sweep through, and none of its paths ask. Same contract
    /// as ``log``.
    nonisolated(unsafe) static var hidePopupsOverBridge:
        @Sendable (PopupSweepScope) async -> [String] = { _ in [] }

    /// Hides any CEF popup window the bottled client has put on screen, and
    /// answers the names it hid for the caller's log.
    ///
    /// The sweep is a single evaluate over the bridge's live connection, and
    /// every ask for one — the supervisor's cycle, a stop's polls, a client
    /// notification's schedule — goes through ``PopupSweeper``, which is what
    /// keeps two of them from running at the same millisecond.
    static func hideVisibleClientPopups(
        _ scope: PopupSweepScope = .everything,
    ) async -> [String] {
        let hide = PerfProbe.supervisor.beginInterval("PopupHide")
        defer { PerfProbe.supervisor.endInterval("PopupHide", hide) }
        return await PopupSweeper.shared.sweep(scope).names
    }

    /// Runs one of the app's standing scripts in the bottled client's own
    /// friends UI, retrying until it answers that it is in place.
    ///
    /// The client runs a second copy of the UI this app hosts, and it reacts
    /// to every event the same way: it opens a CEF chat window for an arriving
    /// message, on the Wine desktop in front of whatever the user was doing,
    /// and it plays Steam's message chime out of a page nobody can see. So
    /// both refusals — ``SteamChatAutoOpen`` and ``SteamMessageSound`` — go to
    /// that copy as well as to the app's own page.
    ///
    /// Answers what the script answered, for the caller's log.
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

    /// Asks the client's own `SharedJSContext` whether `GetServicesInitialized()`
    /// is true — the part that dies with the client's UI session while CDP goes
    /// on listing the target. Nil when the client cannot be reached at all, so
    /// a caller's own cycle decides what a client that stopped answering means.
    ///
    /// Asked over the connection the bridge already holds, for the same reason
    /// the popup sweep is: a boot spends two minutes asking this once a second,
    /// and a fresh DevTools session per ask is a hundred sessions against a
    /// component this project has wedged twice that way. The default opens one
    /// anyway, because a process with no bridge — the `sevo` CLI — still has
    /// the question. Same contract as ``log``.
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

    /// Fresh crash dumps in the client's `dumps/` folder — the crash-loop
    /// signature when the count climbs while the supervisor is restarting.
    ///
    /// Only `.dmp` files count, and only by when they were written: the folder
    /// also holds the bookkeeping the client rewrites at every start, which
    /// counted as three fresh crashes across a night with no crash in it.
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

    /// Whether a swept popup name is the client's own sign-in window
    /// (`SP DesktopLoginWindow_uid0`). A client showing it is signed out and
    /// waiting on a human, which no recovery timer should read as a wedge.
    static func isLoginWindow(_ name: String) -> Bool {
        name.range(of: "DesktopLoginWindow", options: .caseInsensitive) != nil
    }

    /// Trashes the client's Chromium cache — the proven first response to a
    /// crash-looping webhelper. Only safe with the client stopped.
    @discardableResult
    static func purgeHTMLCache() -> Bool {
        (try? FileManager.default.trashItem(at: SteamBottle.htmlcache, resultingItemURL: nil)) != nil
    }

    /// Trashes Steam's shader cache so the next launch rebuilds it — the
    /// response to a black screen or a stuck load a plain restart does not
    /// clear. Only safe with the client stopped; the caller brings the bottle
    /// down first. Answers whether a cache was there to trash. Only
    /// ``SteamBottle/shaderCache`` (`steamapps/shadercache`) is removed, so
    /// saves and game files are never reached.
    @discardableResult
    static func clearShaderCache() -> Bool {
        let cache = SteamBottle.shaderCache
        guard FileManager.default.fileExists(atPath: cache.path) else { return false }
        return (try? FileManager.default.trashItem(at: cache, resultingItemURL: nil)) != nil
    }

    /// Headless client refresh (the lancache-prefill trick): re-downloads the
    /// full client package and exits without logging in. Only safe with the
    /// client stopped. Returns whether the updater exited cleanly.
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

    /// Runs one Windows program inside the Steam bottle to completion — a
    /// dependency installer, a `reg` edit — through the same engine
    /// invocation as the client itself, so the renderer environment and
    /// msync ride along. The program shares the bottle with a running
    /// client; `stopAll` and the supervisor's restart ladder would take it
    /// down with the client, so long installers are best run while Steam
    /// is healthy or stopped.
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
    /// A dependency installer is a minutes-long wine tree. Started from the
    /// app it belongs to the window that asked for it; started from `sevo` it
    /// belongs to a process that exits as soon as the command returns. The
    /// daemon outlives both and is the one owner of bottle processes, so the
    /// tree survives whatever closes above it. The direct fall-back is the
    /// machine with no daemon answering: the first run, before the app has
    /// registered one, and `--no-app`.
    ///
    /// Only a daemon that could not be reached, or that has no `/bottle/run`,
    /// hands the program back to this process. A request that timed out or
    /// broke off may have started the program already, and a second copy of
    /// an installer in the same bottle is worse than a failed run.
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

    /// The `/bottle/run` request one bottle command becomes: one argument per
    /// body line, so a Windows path with spaces stays one argument with no
    /// quoting to undo. The socket's deadline sits past the bottle's own, so
    /// what comes back is the program's answer rather than the socket's.
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

    /// Starts one windowed Windows program inside the Steam bottle — winecfg,
    /// the control panel — and returns as soon as it's spawned, because a
    /// window the user is going to interact with has no useful exit to wait
    /// for. `@concurrent` so the spawn never runs on the calling actor.
    ///
    /// `environment` replaces the invocation's own, for a program that runs
    /// in the bottle's companion prefix (``SteamParent``), and `directory`
    /// is the working directory its Windows side starts in.
    /// - Parameter programExit: For a launcher whose status is the program's
    ///   own — the `steam.exe` parent exits with its child's code — the
    ///   program, so its exit is written to the Wine log for the run record
    ///   to read (``ProgramExit``). Nil for `start /unix`, which returns 0
    ///   the moment the program is spawned.
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
        // The program's own name: a full path in a log line is the account's
        // name in a bug report, and nobody reads past it.
        let name = program.first.map(programName) ?? "?"
        let trail = WineLog.handle(labeled: name) ?? FileHandle.nullDevice
        process.standardOutput = trail
        process.standardError = trail
        process.terminationHandler = { finished in
            let status = finished.terminationStatus
            log(exitLine(of: name, status: status, stopRequestedAt: stopRequestedAt))
            if let programExit {
                trail.write(Data((ProgramExit.line(programExit, status: status) + "\n").utf8))
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

    /// The file name at the end of a path as Windows or as Unix spells it:
    /// `C:\windows\system32\steam.exe` and `/Applications/Game/game.exe` both
    /// name their last component.
    static func programName(of path: String) -> String {
        path.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? path
    }

    /// Closes a log handle whose process never started, which leaves no
    /// termination handler to close it. The null device is shared and stays.
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

    /// The emergency brake when a client update breaks under Wine: pinning
    /// writes `steam.cfg` next to steam.exe. A pinned client eventually loses
    /// connectivity — unpin as soon as the engine fix ships.
    static func setPinned(_ pinned: Bool) throws {
        if pinned {
            try Data("BootStrapperInhibitAll=enable\n".utf8).write(to: SteamBottle.steamCfg)
        } else if FileManager.default.fileExists(atPath: SteamBottle.steamCfg.path) {
            try FileManager.default.trashItem(at: SteamBottle.steamCfg, resultingItemURL: nil)
        }
    }
}
