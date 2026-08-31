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

    static func gracefulShutdown() async {
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
    static func stopAll(gracePolls: Int, phase: (String) -> Void = { _ in }) async {
        let existing = await bottleProcessIDs()
        guard !existing.isEmpty else { return }
        log("bottle processes running (pids \(existing)) — shutting them down")
        phase("stopping the client")
        // `steam.exe -shutdown` only means anything to a live client. When the
        // client has already crashed (the usual reason for a restart), asking
        // a corpse to shut down and then waiting 30 s for it is pure stall —
        // the leftover wineserver/winedevice never answer a client shutdown.
        // Skip straight to the force rung, which brings them down in seconds.
        var clean = false
        if await clientProcessAlive() {
            await gracefulShutdown()
            for _ in 0 ..< gracePolls {
                if await bottleProcessIDs().isEmpty { clean = true; break }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        if !clean {
            phase("force-killing wine")
            log("graceful shutdown timed out — wineserver -k")
            await killWineserver()
            try? await Task.sleep(for: .seconds(3))
            var survivors = await bottleProcessIDs()
            if !survivors.isEmpty {
                log("signalling survivors (pids \(survivors))")
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
        }
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
        let process = Process()
        // -nocrashdialog suppresses steam.exe's VGUI rescue dialog
        // ("Steamwebhelper is not responding"); with it, the client relaunches
        // a wedged webhelper by itself instead of parking a visible Wine
        // window (Docs/resilience-spec.md experiment #1, verified 2026-08-22).
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { finished in
            log("wine launcher exited (status \(finished.terminationStatus))")
        }
        do {
            try process.run()
        } catch {
            log("wine launcher failed to start: \(error.localizedDescription)")
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
    static func hideVisibleClientPopups() async -> [String] {
        guard let targets = try? await CDPClient.discoverTargets(port: BridgePorts.cdp) else {
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
        for target in targets {
            guard target["type"] as? String == "page",
                  (target["url"] as? String)?.hasPrefix("about:blank") == true,
                  let socketURL = (target["webSocketDebuggerUrl"] as? String).flatMap(URL.init),
                  let name = try? await CDPClient.evaluateOnce(socketURL: socketURL, script),
                  !name.isEmpty else { continue }
            hidden.append(name)
        }
        return hidden
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
