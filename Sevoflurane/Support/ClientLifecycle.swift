import Foundation
import os

/// The mechanics of the bottled client's life: probing, launching, and the
/// kill ladder. Policy lives with the callers — the app's ``ClientSupervisor``
/// decides *when* to act, the `sevo` CLI exposes the same actions to a
/// terminal or an agent — so both drive one implementation.
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

    enum ClientState: Equatable {
        case up
        /// CDP answers but lists no `SharedJSContext` — the half-wedged client.
        case portWithoutContext
        case down
    }

    /// A generous timeout: under memory pressure a Rosetta CEF answers
    /// `/json` slowly, and a slow answer must read as "slow", never as
    /// "down" — a false "down" costs a two-minute full restart.
    static func probeClient() async -> ClientState {
        guard let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp, timeout: 10)
        else { return .down }
        return targets.contains { $0["title"] as? String == "SharedJSContext" }
            ? .up : .portWithoutContext
    }

    /// Whether the bottle's client process exists at all, told by command
    /// line (`Steam.exe -silent` is this app's own launch line; the Mac
    /// Steam client is `steam_osx` and cannot match). Cheap on purpose —
    /// one `pgrep`, no per-pid `lsof` scoping — because it runs on the
    /// probe's failure path to separate "CDP is slow" from "nothing is
    /// running".
    static func clientProcessAlive() async -> Bool {
        await Subprocess.run("/usr/bin/pgrep", ["-f", "Steam.exe -silent"]).status == 0
    }

    // MARK: - Processes

    /// PIDs of the bottle's processes, matched by name and then scoped by open
    /// files inside the bottle so other bottles' wine processes are untouched.
    static func bottleProcessIDs(matching name: String? = nil) async -> [pid_t] {
        await bottleProcessIDs(matchingAnyOf: name.map { [$0] } ?? processNames)
    }

    static func bottleProcessIDs(matchingAnyOf names: [String]) async -> [pid_t] {
        var candidates: Set<pid_t> = []
        for processName in names {
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

    /// What a force-quit reaches. `steam` takes the client down and leaves
    /// Windows booted; `everything` tears down the whole fake machine.
    enum ForceScope { case steam, everything }

    /// The escape hatch: immediate `SIGKILL`, no graceful ask and no wait —
    /// for when the graceful ladder is the thing that hung. Scoped by open
    /// files to this bottle, so another engine's wine is never touched.
    /// Answers how many processes it signaled.
    @discardableResult
    static func forceQuit(_ scope: ForceScope) async -> [pid_t] {
        switch scope {
        case .steam:
            let pids = await bottleProcessIDs(matchingAnyOf: steamProcessNames)
            for pid in pids { kill(pid, SIGKILL) }
            log("force-quit: SIGKILL'd \(pids.count) Steam process(es) \(pids)")
            return pids
        case .everything:
            // wineserver -k brings down every process in the prefix — games
            // and service hosts included; the sweep is for anything it missed.
            await killWineserver()
            let pids = await bottleProcessIDs(matchingAnyOf: processNames)
            for pid in pids { kill(pid, SIGKILL) }
            log("force-quit: wineserver -k + SIGKILL'd \(pids.count) survivor(s) \(pids)")
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
            // "C:\Program Files\Steam\steam.exe -silent" → "steam.exe": the
            // path holds spaces, so split on the separators first, then drop
            // the arguments that trail the last component.
            let lastComponent = command
                .split(whereSeparator: { $0 == "/" || $0 == "\\" }).last ?? command
            names[pid] = lastComponent.split(separator: " ").first.map(String.init)
                ?? String(lastComponent)
        }
        return names
    }

    /// One DevTools call — a shutdown ask, a popup hide, a script install —
    /// gets at most this long, and less when its phase's deadline is nearer.
    static let cdpCallCap: Duration = .seconds(5)

    /// A popup sweep made outside a stop phase: the supervisor's cycle, the
    /// login-window sweep, the toast twin.
    static let popupSweepBudget: Duration = .seconds(15)

    /// The smaller of a call's own cap and what remains of its phase.
    private static func cap(_ limit: Duration, until deadline: ContinuousClock.Instant) -> Duration {
        min(limit, ContinuousClock.now.duration(to: deadline))
    }

    /// Asks the client to exit. The CDP ask is bounded by `deadline`; the
    /// spawn fallback carries its own subprocess timeout.
    static func gracefulShutdown(until deadline: ContinuousClock.Instant) async {
        // The quiet path first: StartShutdown in the client's own JS context.
        // `steam.exe -shutdown` spawns a whole second client instance just to
        // deliver the message — seconds of bottle work to say one word. The
        // spawn is the fallback for a client whose CDP is gone, and it goes
        // through the same suppressed environment as every other spawn.
        if await shutdownOverCDP(until: deadline) { return }
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .none,
            program: [SteamBottle.exeWindowsPath, "-shutdown"],
        )
        _ = await Subprocess.run(
            invocation.executable.path,
            invocation.arguments,
            environment: invocation.environment,
            capture: .none,
            timeout: .seconds(30),
        )
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

    static func killWineserver() async {
        // CX_BOTTLE is not honored here; wineserver needs WINEPREFIX.
        _ = await Subprocess.run(
            Engine.active.wineserverURL.path,
            ["-k"],
            environment: ["WINEPREFIX": SteamBottle.root.path, "PATH": "/usr/bin"],
            capture: .none,
            timeout: .seconds(15),
        )
    }

    /// Brings every bottle process down: graceful `-shutdown`, then
    /// `wineserver -k`, then signals, each rung only for what the previous
    /// one left alive. `gracePolls` bounds the graceful rung at 2 s per
    /// poll — a restart can afford 30 s of patience, quit cannot.
    /// Stops Steam and leaves Windows booted: wineserver, services and the
    /// device hosts stay resident, so the next client start skips the
    /// machine boot entirely. The callers decide when Windows itself must
    /// go instead (`stopAll`): a different engine's wineserver, an msync
    /// change (sync primitives are negotiated with the server), a quit.
    static func stopClient(
        gracePolls: Int,
        phase: (String) -> Void = { _ in },
    ) async {
        let existing = await bottleProcessIDs(matchingAnyOf: steamProcessNames)
        guard !existing.isEmpty else { return }
        log("stopping the client — Windows stays up (pids \(existing))")
        phase("stopping the client")
        let stopBegan = ContinuousClock.now
        let cdpDeadline = stopBegan + cdpBudget(gracePolls: gracePolls)
        if await clientProcessAlive() {
            await gracefulShutdown(until: cdpDeadline)
        }
        for _ in 0 ..< gracePolls {
            _ = await hideVisibleClientPopups(until: cdpDeadline)
            if await bottleProcessIDs(matchingAnyOf: steamProcessNames).isEmpty {
                log("stop audit: client-only graceful exit in "
                    + "\(stopBegan.duration(to: .now).components.seconds)s")
                return
            }
            try? await Task.sleep(for: .seconds(1))
        }
        phase("force-quitting Steam")
        var survivors = await bottleProcessIDs(matchingAnyOf: steamProcessNames)
        log("stop audit: client-only stop forcing after "
            + "\(stopBegan.duration(to: .now).components.seconds)s (pids \(survivors))")
        for pid in survivors {
            kill(pid, SIGTERM)
        }
        try? await Task.sleep(for: .seconds(2))
        survivors = await bottleProcessIDs(matchingAnyOf: steamProcessNames)
        for pid in survivors {
            kill(pid, SIGKILL)
        }
        try? await Task.sleep(for: .seconds(1))
    }

    /// Everything a stop says to the client over CDP — the shutdown ask and
    /// each poll's popup sweep — draws on one absolute deadline: the ask's
    /// cap plus the grace in seconds. A mute target can hold the ladder for
    /// at most this long however many polls sweep it; the force rung's
    /// subprocesses carry their own timeouts.
    private static func cdpBudget(gracePolls: Int) -> Duration {
        cdpCallCap + .seconds(gracePolls)
    }

    static func stopAll(
        gracePolls: Int,
        hidingPopups: Bool = false,
        phase: (String) -> Void = { _ in },
    ) async {
        let existing = await bottleProcessIDs()
        guard !existing.isEmpty else { return }
        log("bottle processes running (pids \(existing)) — shutting them down")
        phase("stopping the client")
        // `steam.exe -shutdown` only means anything to a live client. When the
        // client has already crashed (the usual reason for a restart), asking
        // a corpse to shut down and then waiting 30 s for it is pure stall —
        // the leftover wineserver/winedevice never answer a client shutdown.
        // Skip straight to the force rung, which brings them down in seconds.
        let stopBegan = ContinuousClock.now
        let cdpDeadline = stopBegan + cdpBudget(gracePolls: gracePolls)
        var clean = false
        if await clientProcessAlive() {
            await gracefulShutdown(until: cdpDeadline)
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
                    _ = await hideVisibleClientPopups(until: cdpDeadline)
                }
                if await bottleProcessIDs().isEmpty { clean = true; break }
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
        await killWineserver()
        try? await Task.sleep(for: .seconds(3))
        var survivors = await bottleProcessIDs()
        if !survivors.isEmpty {
            log("signaling survivors (pids \(survivors))")
            for pid in survivors {
                kill(pid, SIGTERM)
            }
            try? await Task.sleep(for: .seconds(3))
            survivors = await bottleProcessIDs()
            for pid in survivors {
                kill(pid, SIGKILL)
            }
            try? await Task.sleep(for: .seconds(1))
        }
        log("stop audit: forced down in "
            + "\(stopBegan.duration(to: .now).components.seconds)s")
    }

    /// Fire and forget: the wine launcher regularly outlives its useful work
    /// by half a minute, so CDP polling — not the launcher exiting — decides
    /// whether the client is up. The exit is still logged for the trail.
    /// `@concurrent` so the spawn never runs on the calling actor.
    /// Extra `steam.exe` arguments from `SEVO_STEAM_ARGS` in the app's
    /// environment, whitespace-separated — an experiment knob (`-nojoy`,
    /// `-noshaders`, `-cef-*`) that reaches the client through the
    /// supervisor's own launch path.
    static var extraClientArguments: [String] {
        (ProcessInfo.processInfo.environment["SEVO_STEAM_ARGS"] ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
    }

    @concurrent
    static func launchClient() async {
        // Reconcile the engine tree to the desired selection before steam.exe
        // loads anything: the renderer DLLs and both halves of the picked
        // D3DMetal version, staged together. This is the single point graphics
        // effects happen, so a record-only picker takes effect at the next
        // spawn with no chance of a crossed tree.
        BottleGraphics.reconcileManagedTree()
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
            log("wine launcher exited (status \(finished.terminationStatus))")
            try? trail.close()
        }
        // The per-bottle and per-program env files the engine reads at
        // every process start, from the store as it stands now.
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
        do {
            try process.run()
            // Games inherit this environment; remember what it was so a
            // later selection change knows a restart is owed.
            BottleGraphics.recordBootedSelection()
        } catch {
            log("wine launcher failed to start: \(error.localizedDescription)")
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
    }

    // MARK: - Client window suppression

    /// Hides any CEF popup window the bottled client has put on screen.
    ///
    /// The client's CEF windows exist to keep Steam's JS running — rendering
    /// is this app's job, and the page mirrors every popup natively
    /// (``SteamWebHost/adoptPopup(configuration:features:)``). The client
    /// still shows its own window when it decides UI is needed — the
    /// first-run login window above all, which OSS Wine paints as a black
    /// rectangle. Each visible popup is put away through its own
    /// `SteamClient.Window` binding, the same call the client uses to keep
    /// the same window parked when signed in, so the popup's JS stays alive
    /// and only the pixels go. `SharedJSContext` is never a candidate: popups
    /// are the targets the popup manager opened onto `about:blank`.
    ///
    /// Returns the names of the windows it hid, for the caller's log.
    ///
    /// Each target's session gets the smaller of ``cdpCallCap`` and what is
    /// left before `deadline`; a target the sweep reaches after the deadline
    /// is skipped, so a run of mute targets ends the sweep instead of
    /// stretching it. The sweep is optional work everywhere it is called.
    static func hideVisibleClientPopups(
        port: Int = BridgePorts.cdp,
        until deadline: ContinuousClock.Instant = .now + popupSweepBudget,
    ) async -> [String] {
        guard ContinuousClock.now < deadline,
              let targets = try? await CDPClient.discoverTargets(port: port) else {
            return []
        }
        // One DevTools session per popup target, in series — the interval
        // is what a busy CEF turns that into.
        let hide = PerfProbe.supervisor.beginInterval(
            "PopupHide", "targets=\(targets.count, privacy: .public)",
        )
        defer { PerfProbe.supervisor.endInterval("PopupHide", hide) }
        let script = """
        (function () {
          if (document.visibilityState !== "visible") return "";
          if (!window.SteamClient || !SteamClient.Window
              || !SteamClient.Window.HideWindow) return "";
          SteamClient.Window.HideWindow();
          return window.name || "unnamed popup";
        })()
        """
        var hidden: [String] = []
        for target in targets where ContinuousClock.now < deadline {
            guard target["type"] as? String == "page",
                  (target["url"] as? String)?.hasPrefix("about:blank") == true,
                  let socketURL = (target["webSocketDebuggerUrl"] as? String).flatMap(URL.init)
            else { continue }
            let name = try? await withDeadline(cap(cdpCallCap, until: deadline)) {
                try await CDPClient.evaluateOnce(socketURL: socketURL, script)
            }
            guard let name, !name.isEmpty else { continue }
            hidden.append(name)
        }
        return hidden
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

    // MARK: - Crash-loop hygiene

    /// Fresh dumps in the client's `dumps/` folder — the crash-loop signature
    /// when the count climbs while the supervisor is restarting.
    static func recentDumpCount(within interval: TimeInterval = 600) -> Int {
        let cutoff = Date.now.addingTimeInterval(-interval)
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: SteamBottle.dumps, includingPropertiesForKeys: [.contentModificationDateKey],
        ) else { return 0 }
        return files.count { file in
            let date = try? file.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate
            return date.map { $0 > cutoff } ?? false
        }
    }

    /// Trashes the client's Chromium cache — the proven first response to a
    /// crash-looping webhelper. Only safe with the client stopped.
    @discardableResult
    static func purgeHTMLCache() -> Bool {
        (try? FileManager.default.trashItem(at: SteamBottle.htmlcache, resultingItemURL: nil)) != nil
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

    /// Starts one windowed Windows program inside the Steam bottle — winecfg,
    /// the control panel — and returns as soon as it's spawned, because a
    /// window the user is going to interact with has no useful exit to wait
    /// for. `@concurrent` so the spawn never runs on the calling actor.
    @concurrent
    static func launchInBottle(_ program: [String]) async {
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name, wait: .none, program: program,
        )
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = invocation.environment {
            process.environment = environment
        }
        let name = program.first ?? "?"
        let trail = WineLog.handle(labeled: name) ?? FileHandle.nullDevice
        process.standardOutput = trail
        process.standardError = trail
        process.terminationHandler = { finished in
            log("\(name) exited (status \(finished.terminationStatus))")
            try? trail.close()
        }
        do {
            try process.run()
        } catch {
            log("\(name) failed to start: \(error.localizedDescription)")
        }
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
