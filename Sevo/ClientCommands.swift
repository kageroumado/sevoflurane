import ArgumentParser
import Foundation

// MARK: - client

struct ClientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "client",
        abstract: "Start, stop, restart and update the Steam client, through the supervisor.",
        subcommands: [
            Start.self, Stop.self, Restart.self, ForceQuit.self, Update.self,
            ClearShaderCache.self, Pin.self, Unpin.self, Logs.self,
        ],
    )

    /// The escape hatch when a graceful stop is itself hung. Every field of
    /// the reply is observed after the fact — the caller's model updates from
    /// what actually happened, not from "done".
    struct ForceQuit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "force-quit",
            abstract: "SIGKILL now; report what died, what survived, and what came back.",
            discussion: """
            scope 'steam' kills the client and leaves the bottle's Windows processes up; \
            'all' runs wineserver -k and kills the whole bottle, games included. \
            With supervision running the client is brought back clean afterward. \
            The reply is the observation, not a verdict: killed, still-running \
            (for 'steam' the Windows hosts left booted; for 'all' a kill that \
            did not take), recovered (what restarted), and the client's final \
            CDP state — poll again with `sevo status` for more.
            """,
        )
        @Argument(help: "'steam' (client only) or 'all' (the whole bottle).")
        var scope: String = "steam"
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false
        @Flag(name: .customLong("no-app"), help: "Kill directly even if the daemon is running (it will not restart the client).")
        var noApp = false

        func run() async throws {
            let force: ClientLifecycle.ForceScope =
                ["all", "everything"].contains(scope) ? .everything : .steam
            let scopeName = force == .everything ? "everything" : "steam"
            let before = await ClientLifecycle.bottleProcessIDs()
            // Names have to be read before the kill — a dead pid has no `ps`
            // entry — so the reply can still say what it killed.
            let beforeNames = await ClientLifecycle.processNames(before)
            let routed = await ClientOps.supervisionIsRunning(noApp: noApp)
            if routed {
                _ = await AppControl.post("/client/forcequit?scope=\(scopeName)")
            } else {
                _ = await ClientLifecycle.forceQuit(force)
            }
            // Observe the kill settling and, when routed, the client coming
            // back — the reply carries the after-state, not an assumption.
            var after = before
            var clientState = ClientLifecycle.ClientState.down
            for _ in 0 ..< 12 {
                try? await Task.sleep(for: .seconds(2))
                after = await ClientLifecycle.bottleProcessIDs()
                clientState = await ClientLifecycle.probeClient()
                if clientState == .up { break }
                if !routed, after.isEmpty { break }
            }
            let afterSet = Set(after), beforeSet = Set(before)
            let killed = before.filter { !afterSet.contains($0) }
            // Still running: for 'steam' these are the Windows hosts left
            // booted by design; for 'all' anything here is a kill that did
            // not take. Neutral name — the scope decides which it is.
            let stillRunning = before.filter { afterSet.contains($0) }
            let recovered = after.filter { !beforeSet.contains($0) }
            // killed/still-running from the pre-kill read, recovered from a live one.
            let names = await beforeNames.merging(
                ClientLifecycle.processNames(recovered),
            ) { _, new in new }
            let clientText = switch clientState {
            case .up: "running"
            case .portWithoutContext: "half-wedged (no SharedJSContext)"
            case .busy: "running, CDP too busy to answer"
            case .down: "down"
            }
            func label(_ pid: pid_t) -> String {
                "\(names[pid] ?? "?")(\(pid))"
            }
            func rows(_ pids: [pid_t]) -> [[String: Any]] {
                pids.map { ["pid": Int($0), "name": names[$0] ?? "?"] }
            }
            if asJSON {
                print(Sevo.json([
                    "scope": scopeName,
                    "routed_through_app": routed,
                    "killed": rows(killed),
                    "still_running": rows(stillRunning),
                    "recovered": rows(recovered),
                    "client_state": clientText,
                ], pretty: true))
            } else {
                print("force-quit (\(scopeName)) \(routed ? "via the daemon" : "direct"):")
                print("  killed: \(killed.isEmpty ? "none" : killed.map(label).joined(separator: ", "))")
                if !stillRunning.isEmpty {
                    print("  still running: \(stillRunning.map(label).joined(separator: ", "))")
                }
                if !recovered.isEmpty {
                    print("  recovered: \(recovered.map(label).joined(separator: ", "))")
                }
                print("  client now: \(clientText)")
            }
        }
    }

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start", abstract: "Start the bottled client.",
        )
        @Flag(name: .customLong("no-app"), help: "Drive the client directly even if the daemon is running.")
        var noApp = false
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.start(noApp: noApp) { narrate($0, asJSON: asJSON) }
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop the client (graceful → wineserver -k → signals).",
        )
        @Flag(name: .customLong("no-app")) var noApp = false
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.stop(noApp: noApp) { narrate($0, asJSON: asJSON) }
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restart", abstract: "Stop, then start.",
        )
        @Flag(name: .customLong("no-app")) var noApp = false
        @Flag(name: .customLong("windows"), help: "Stop every Windows process in the bottle, Wine's server included, and start again.")
        var windows = false
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.restart(
                    noApp: noApp, windows: windows,
                ) { narrate($0, asJSON: asJSON) }
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct ClearShaderCache: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "clear-shader-cache",
            abstract: "Trash Steam's shader cache and relaunch (fixes a black screen or stuck load).",
            discussion: """
            Removes steamapps/shadercache only; Steam rebuilds it on the next \
            launch. Saves and game files are untouched. With supervision \
            running the bottle is stopped, cleared, and brought back in one \
            step; --no-app stops and clears, then leaves the relaunch to \
            `sevo client start`.
            """,
        )
        @Flag(name: .customLong("no-app")) var noApp = false
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.clearShaderCache(noApp: noApp) {
                    narrate($0, asJSON: asJSON)
                }
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Headless client refresh (client must be stopped).",
        )
        @Flag(name: .customLong("json"), help: "Machine-readable observation.")
        var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.update { narrate($0, asJSON: asJSON) }
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct Pin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pin",
            abstract: "Inhibit client self-updates (emergency brake; unpin when the engine fix ships).",
        )

        func run() async throws {
            do {
                try ClientLifecycle.setPinned(true)
            } catch {
                Sevo.printError("could not write steam.cfg: \(error.localizedDescription)")
                throw SevoExit.failed
            }
            print("client updates pinned (steam.cfg: BootStrapperInhibitAll=enable)")
        }
    }

    struct Unpin: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "unpin", abstract: "Re-enable client self-updates.",
        )

        func run() async throws {
            do {
                try ClientLifecycle.setPinned(false)
            } catch {
                Sevo.printError("could not remove steam.cfg: \(error.localizedDescription)")
                throw SevoExit.failed
            }
            print("client updates unpinned")
        }
    }

    struct Logs: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "logs", abstract: "Alias for `sevo logs`.",
        )
        @Option(name: .customLong("tail")) var tail: Int = 50
        @Flag(name: .shortAndLong) var follow = false

        func run() async throws {
            try await LogsCommand.tail(lines: tail, follow: follow)
        }
    }
}

struct RecoverCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "recover",
        abstract: "Bring a stuck client back: probe, reload the interface, restart.",
        discussion: "--deep adds htmlcache hygiene and a headless client repair pass.",
    )

    @Flag(help: "Also trash the htmlcache and repair the client.") var deep = false
    @Flag(name: .customLong("no-app")) var noApp = false
    @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

    func run() async throws {
        try await handlingFailures {
            let outcome = try await ClientOps.recover(deep: deep, noApp: noApp) {
                narrate($0, asJSON: asJSON)
            }
            await StatusReport.emit(outcome, asJSON: asJSON)
        }
    }
}

// MARK: - daemon

struct DaemonCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "daemon",
        abstract: "The background helper that owns the bottle.",
        subcommands: [Repair.self],
    )

    /// Rebuilds the background helper's registration — the fix for a helper
    /// that will not launch because a stale Background Task Management record
    /// still carries a Development code requirement. Only the app can do it
    /// (`SMAppService` acts for the bundle that registered the helper), so
    /// this asks the running app rather than the daemon, which is exactly
    /// what is down.
    struct Repair: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair",
            abstract: "Rebuild the background helper's registration (unregister, then register).",
            discussion: "A no-op when the helper is already answering. Pass --force to "
                + "rebuild anyway: the helper is replaced, Steam goes down with it, and "
                + "the app attaches to the new helper and brings the client back. "
                + "Needs Sevoflurane running: only the app can rebuild the "
                + "registration. macOS may ask you to approve the helper again "
                + "in Login Items afterward.",
        )
        @Flag(name: .customLong("json")) var asJSON = false
        @Flag(name: .customLong("force"), help: "Rebuild even when the helper is already healthy.")
        var force = false

        func run() async throws {
            let path = force ? "/daemon/repair?force=1" : "/daemon/repair"
            // The old helper's teardown, the new one's start and its attach
            // to the app are each bounded by the app; this outlasts all three.
            guard let reply = await AppControl.appLinkPost(path, timeout: 120) else {
                Sevo.printError("Sevoflurane is not running — open it and try again "
                    + "(only the app can rebuild the helper's registration).")
                throw SevoExit.unreachable
            }
            let object = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
            let result = object?["result"] as? String ?? "failed"
            let note = object?["note"] as? String ?? ""
            if asJSON {
                print(Sevo.json(["result": result, "note": note], pretty: true))
            } else {
                print("daemon repair: \(result)" + (note.isEmpty ? "" : " — \(note)"))
            }
            if result == "failed" { throw SevoExit.failed }
        }
    }
}
