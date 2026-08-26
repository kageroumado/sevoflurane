import ArgumentParser
import Foundation

/// `sevo` — one management surface, three consumers: us (testing and
/// debugging), terminal-comfortable end users, and AI agents (via `sevo mcp`
/// or by just running the CLI). Design: `Docs/cli-mcp-spec.md`.
@main
struct SevoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sevo",
        abstract: "Manage Sevoflurane's bottled Steam client.",
        version: Sevo.version,
        subcommands: [
            DoctorCommand.self, StatusCommand.self,
            EngineCommand.self, BottleCommand.self,
            ClientCommand.self, RecoverCommand.self,
            AppCommand.self, DownloadsCommand.self,
            EvalCommand.self, CDPCommand.self, LogsCommand.self,
            MCPCommand.self, InstallCLICommand.self, VersionCommand.self,
        ],
    )
}

/// Maps operation failures onto the exit contract with the message on stderr.
nonisolated func handlingFailures(_ body: () async throws -> Void) async throws {
    do {
        try await body()
    } catch let failure as ClientOps.Failure {
        switch failure {
        case let .message(message):
            Sevo.printError(message)
            throw SevoExit.failed
        case let .unprovisioned(message):
            Sevo.printError(message)
            throw SevoExit.notProvisioned
        }
    } catch let failure as CDPClient.Failure {
        switch failure {
        case let .unreachable(detail):
            Sevo.printError("client unreachable: \(detail) — try: sevo client start")
            throw SevoExit.unreachable
        case .closed, .badReply:
            Sevo.printError("client eval failed: \(failure)")
            throw SevoExit.failed
        }
    }
}

// MARK: - doctor / status

struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Full environment diagnosis, one ✔/✖ line per check.",
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let snapshot = await Doctor.snapshot()
        let checks = Doctor.checks(from: snapshot)
        if asJSON {
            print(Sevo.json(Doctor.jsonReport(from: snapshot, checks: checks), pretty: true))
        } else {
            print("sevo doctor")
            for check in checks {
                let mark = check.ok ? "✔" : "✖"
                print("  \(mark) \(check.label)" + (check.ok ? "" : " — \(check.hint)"))
            }
        }
        if checks.contains(where: { !$0.ok && $0.provisioning }) { throw SevoExit.notProvisioned }
        if checks.contains(where: { !$0.ok }) { throw SevoExit.failed }
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "One line: engine, bottle, client, bridge, app.",
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let snapshot = await Doctor.snapshot()
        let d = snapshot.detection
        let engine = if let cx = d.crossover {
            "CrossOver \(cx.version)"
        } else if let managed = d.managedEngineVersions.last {
            "builtin \(managed)"
        } else {
            "NONE"
        }
        let steamOK = d.bottles.first { $0.name == SteamBottle.name }?.hasSteam == true
        let client = switch snapshot.clientState {
        case .up: "running"
        case .portWithoutContext: "half-wedged (no SharedJSContext)"
        case .down: snapshot.bottleProcesses.isEmpty ? "stopped" : "up, CDP unreachable"
        }
        let app = if let status = snapshot.appStatus {
            "running (\(status["health"] as? String ?? "?"))"
        } else {
            "not running"
        }
        if asJSON {
            let report: [String: Any] = [
                "engine": engine,
                "bottle": SteamBottle.name,
                "steam_installed": steamOK,
                "client": client,
                "services_up": snapshot.servicesUp ?? NSNull(),
                "bridge": snapshot.bridgeUp,
                "app": snapshot.appStatus ?? NSNull(),
                "dump_rate_10m": snapshot.dumpCount,
                "client_pinned": snapshot.pinned,
            ]
            print(Sevo.json(report, pretty: true))
        } else {
            print("engine \(engine) · bottle \(SteamBottle.name) (\(steamOK ? "steam ok" : "no steam"))"
                + " · client \(client) · bridge \(snapshot.bridgeUp ? "up" : "down")"
                + " · app \(app)")
        }
    }
}

// MARK: - engine / bottle

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Wine engines (CrossOver, managed OSS).",
    )

    @Argument(help: "list | install") var verb: String = "list"
    @Option(
        name: .customLong("manifest"),
        help: "Manifest URL override (default: the kagerou.glass manifest).",
    ) var manifest: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "install":
            try await install()
        default:
            Sevo.printError("engine \(verb): unknown verb (list | install)")
            throw SevoExit.badInvocation
        }
    }

    /// Downloads and installs the manifest's stable release — the CLI face
    /// of the wizard's built-in-engine stage (release-plan R2.2).
    private func install() async throws {
        let manifestURL = try manifest.map {
            guard let url = URL(string: $0) else {
                Sevo.printError("not a URL: \($0)")
                throw SevoExit.badInvocation
            }
            return url
        } ?? EngineManifest.url
        do {
            let fetched = try await EngineManifest.fetch(from: manifestURL)
            guard let release = fetched.stable else {
                Sevo.printError("manifest has no stable channel")
                throw SevoExit.failed
            }
            guard !EngineInstaller.isInstalled(release) else {
                print("engine \(release.version) already installed")
                return
            }
            try await EngineInstaller.install(release) { phase in
                FileHandle.standardError.write(Data((phase + "\n").utf8))
            }
            print("engine \(release.version) installed")
        } catch let code as ExitCode {
            throw code
        } catch {
            Sevo.printError("engine install failed: \(error)")
            throw SevoExit.failed
        }
    }

    private func list() async throws {
        let d = await SetupProbe.detect()
        var rows: [[String: Any]] = []
        if let cx = d.crossover {
            rows.append([
                "engine": "crossover", "version": cx.version, "licensed": cx.licensed,
                "expires": cx.expires ?? NSNull(), "trial_expired": cx.trialExpired,
            ])
        }
        for version in d.managedEngineVersions {
            rows.append(["engine": "builtin", "version": version])
        }
        if asJSON {
            print(Sevo.json(rows, pretty: true))
        } else if rows.isEmpty {
            print("no engines")
        } else {
            for row in rows {
                print("\(row["engine"] ?? "?") \(row["version"] ?? "?")")
            }
        }
    }
}

struct BottleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle",
        abstract: "CrossOver bottles and whether Steam is installed in each.",
    )

    @Argument(help: "list | config") var verb: String = "list"
    @Argument(help: "Config key: renderer | msync. Omit to print every key.")
    var key: String?
    @Argument(help: "New value. Omit to read the key.") var value: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "config":
            try config()
        default:
            Sevo.printError("bottle \(verb): unknown verb (list | config)")
            throw SevoExit.badInvocation
        }
    }

    /// Reads or writes the graphics knobs the app's Settings › Graphics pane
    /// drives, against the same store (`Sevoflurane/Support/BottleGraphics.swift`).
    private func config() throws {
        var selection = current()
        guard let key else {
            if asJSON {
                print(Sevo.json([
                    "renderer": selection.renderer.rawValue,
                    "msync": selection.msync,
                ], pretty: true))
            } else {
                print("renderer \(selection.renderer.rawValue)")
                print("msync \(selection.msync)")
            }
            return
        }
        guard let value else {
            switch key {
            case "renderer": print(selection.renderer.rawValue)
            case "msync": print(selection.msync)
            default:
                Sevo.printError("unknown key '\(key)' (renderer | msync)")
                throw SevoExit.badInvocation
            }
            return
        }
        switch key {
        case "renderer":
            guard let renderer = Renderer(rawValue: value) else {
                Sevo.printError("renderer must be one of: "
                    + Renderer.allCases.map(\.rawValue).joined(separator: ", "))
                throw SevoExit.badInvocation
            }
            selection.renderer = renderer
        case "msync":
            guard let flag = Bool(value) else {
                Sevo.printError("msync must be true or false")
                throw SevoExit.badInvocation
            }
            selection.msync = flag
        default:
            Sevo.printError("unknown key '\(key)' (renderer | msync)")
            throw SevoExit.badInvocation
        }
        do {
            try apply(selection)
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
        print("\(key) \(value) — takes effect at the next game launch")
    }

    private func current() -> BottleGraphics.Selection {
        Engine.active == .crossover
            ? BottleGraphics.selection(forBottle: SteamBottle.root)
            : BottleGraphics.managedSelection()
    }

    private func apply(_ selection: BottleGraphics.Selection) throws {
        switch Engine.active {
        case .crossover:
            try BottleGraphics.apply(selection, toBottle: SteamBottle.root)
        case .managed:
            BottleGraphics.setManagedSelection(selection)
        }
    }

    private func list() async throws {
        let bottles = await SetupProbe.detect().bottles
        if asJSON {
            let rows = bottles.map { ["name": $0.name, "steam": $0.hasSteam] as [String: Any] }
            print(Sevo.json(rows, pretty: true))
        } else if bottles.isEmpty {
            print("no bottles")
        } else {
            for bottle in bottles {
                print("\(bottle.name)  [\(bottle.hasSteam ? "steam" : "empty")]")
            }
        }
    }
}

// MARK: - client

struct ClientCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "client",
        abstract: "Client lifecycle: full ladder semantics, never raw wine calls.",
        subcommands: [
            Start.self, Stop.self, Restart.self, Update.self,
            Pin.self, Unpin.self, Logs.self,
        ],
    )

    struct Start: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "start", abstract: "Start the bottled client.",
        )
        @Flag(name: .customLong("no-app"), help: "Drive the client directly even if the app is running.")
        var noApp = false

        func run() async throws {
            try await handlingFailures {
                try await ClientOps.start(noApp: noApp) { print($0) }
            }
        }
    }

    struct Stop: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "stop",
            abstract: "Stop the client (graceful → wineserver -k → signals).",
        )
        @Flag(name: .customLong("no-app")) var noApp = false

        func run() async throws {
            try await handlingFailures {
                try await ClientOps.stop(noApp: noApp) { print($0) }
            }
        }
    }

    struct Restart: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restart", abstract: "Stop, then start.",
        )
        @Flag(name: .customLong("no-app")) var noApp = false

        func run() async throws {
            try await handlingFailures {
                try await ClientOps.restart(noApp: noApp) { print($0) }
            }
        }
    }

    struct Update: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "update",
            abstract: "Headless client refresh (client must be stopped).",
        )

        func run() async throws {
            try await handlingFailures {
                try await ClientOps.update { print($0) }
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
        abstract: "The wedge playbook: probe → reload → restart.",
        discussion: "--deep adds htmlcache hygiene and a headless client repair pass.",
    )

    @Flag(help: "Also trash the htmlcache and repair the client.") var deep = false
    @Flag(name: .customLong("no-app")) var noApp = false

    func run() async throws {
        try await handlingFailures {
            try await ClientOps.recover(deep: deep, noApp: noApp) { print($0) }
        }
    }
}

// MARK: - app / downloads

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Library and per-app actions via the client's own API.",
        subcommands: [
            List.self, Info.self, Launch.self, Terminate.self,
            Install.self, Uninstall.self, Verify.self,
        ],
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "The library (appid, name, state).",
        )
        @Flag(help: "Only installed apps.") var installed = false
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            var raw = "[]"
            try await handlingFailures {
                raw = try await SteamOps.libraryList(installedOnly: installed)
            }
            if asJSON {
                print(raw)
                return
            }
            guard let apps = try? JSONSerialization.jsonObject(with: Data(raw.utf8))
                as? [[String: Any]] else {
                print(raw)
                return
            }
            for app in apps {
                let appid = app["appid"] as? Int ?? 0
                let name = app["name"] as? String ?? "?"
                let installed = app["installed"] as? Bool == true
                print("\(String(appid).padding(toLength: 8, withPad: " ", startingAt: 0))"
                    + " \(installed ? "●" : "○") \(name)")
            }
        }
    }

    struct Info: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "info", abstract: "One app's overview (JSON).",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await print(SteamOps.appInfo(appid))
            }
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch", abstract: "Apps.RunGame.",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.launch(appid)
                print("launch requested for \(appid)")
            }
        }
    }

    struct Terminate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "terminate", abstract: "Apps.TerminateApp.",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.terminate(appid)
                print("terminate requested for \(appid)")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: "Queue an install with the default folder.",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.install(appid)
                print("install queued for \(appid) — watch: sevo downloads status")
            }
        }
    }

    struct Uninstall: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "uninstall",
            abstract: "Uninstall an app. Requires --name matching the app, as a guard.",
        )
        @Argument var appid: Int
        @Option(help: "The app's display name, echoed back as confirmation.")
        var name: String

        func run() async throws {
            try await handlingFailures {
                try await uninstall()
            }
        }

        private func uninstall() async throws {
            guard let actual = try await SteamOps.appName(appid) else {
                Sevo.printError("appid \(appid) is not in the library")
                throw SevoExit.failed
            }
            guard actual.lowercased() == name.lowercased() else {
                Sevo.printError("name mismatch: appid \(appid) is \"\(actual)\" — not uninstalling")
                throw SevoExit.badInvocation
            }
            try await SteamOps.uninstall(appid)
            print("uninstall requested for \(appid) (\(actual))")
        }
    }

    struct Verify: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "verify", abstract: "Apps.VerifyApp (validate local files).",
        )
        @Argument var appid: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.verify(appid)
                print("verify requested for \(appid) — watch: sevo downloads status")
            }
        }
    }
}

struct DownloadsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "downloads",
        abstract: "Download queue: status, pause, resume, throttle.",
        subcommands: [Status.self, Pause.self, Resume.self, Throttle.self],
    )

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "One DownloadOverview snapshot (JSON).",
        )

        func run() async throws {
            try await handlingFailures {
                try await print(SteamOps.downloadsStatus())
            }
        }
    }

    struct Pause: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "pause", abstract: "Disable all downloads.",
        )

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.setDownloadsEnabled(false)
                print("downloads paused")
            }
        }
    }

    struct Resume: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "resume", abstract: "Re-enable downloads.",
        )

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.setDownloadsEnabled(true)
                print("downloads resumed")
            }
        }
    }

    struct Throttle: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "throttle", abstract: "Limit download speed in KB/s (0 = off).",
        )
        @Argument var kbps: Int

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.throttle(kbps)
                print(kbps == 0 ? "throttle off" : "throttled to \(kbps) KB/s")
            }
        }
    }
}

// MARK: - debug channels

struct EvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "eval",
        abstract: "JavaScript in the app's page context via the bridge (debug).",
    )
    @Argument var js: String

    func run() async throws {
        do {
            let result = try await BridgeEval.eval(js)
            print(result.value)
            if !result.ok { throw SevoExit.failed }
        } catch BridgeEval.Failure.unreachable {
            Sevo.printError("bridge unreachable on :\(BridgePorts.steamUI) — is Sevoflurane running?")
            throw SevoExit.unreachable
        } catch BridgeEval.Failure.malformedReply {
            Sevo.printError("malformed /__eval reply")
            throw SevoExit.failed
        }
    }
}

struct CDPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cdp",
        abstract: "JavaScript in the bottled client via CDP (debug).",
    )
    @Argument var js: String
    @Argument(help: "Target title (default SharedJSContext).")
    var target: String = "SharedJSContext"

    func run() async throws {
        let client = CDPClient(onPush: { _ in })
        do {
            try await client.connect(port: BridgePorts.cdp, targetTitle: target)
            try await print(client.evaluate(js) ?? "null")
        } catch let failure as CDPClient.Failure {
            if case let .unreachable(detail) = failure {
                Sevo.printError("client unreachable: \(detail)")
                throw SevoExit.unreachable
            }
            Sevo.printError("eval failed: \(failure)")
            throw SevoExit.failed
        }
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "The unified event log.",
    )
    @Option(name: .customLong("tail")) var tail: Int = 50
    @Flag(name: .shortAndLong) var follow = false

    func run() async throws {
        try await Self.tail(lines: tail, follow: follow)
    }

    static func tail(lines: Int, follow: Bool) async throws {
        guard let handle = try? FileHandle(forReadingFrom: Sevo.logFile) else {
            Sevo.printError("no log file at \(Sevo.logFile.path) — has the app ever run?")
            throw SevoExit.failed
        }
        let existing = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        for line in existing.split(separator: "\n").suffix(max(1, lines)) {
            print(line)
        }
        guard follow else { return }
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            if let data = try? handle.readToEnd(), !data.isEmpty {
                FileHandle.standardOutput.write(data)
            }
        }
    }
}

// MARK: - housekeeping

struct InstallCLICommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "install-cli",
        abstract: "Symlink sevo into /usr/local/bin.",
    )

    func run() async throws {
        let target = URL(fileURLWithPath: "/usr/local/bin/sevo")
        guard let source = Bundle.main.executableURL?.resolvingSymlinksInPath() else {
            throw SevoExit.failed
        }
        let manager = FileManager.default
        do {
            // Replace only something that is itself a symlink; anything else
            // at that path is not ours to overwrite.
            if let existing = try? manager.destinationOfSymbolicLink(atPath: target.path) {
                if existing == source.path {
                    print("already installed: \(target.path) → \(source.path)")
                    return
                }
                try manager.removeItem(at: target)
            }
            try manager.createSymbolicLink(at: target, withDestinationURL: source)
            print("installed: \(target.path) → \(source.path)")
        } catch {
            Sevo.printError("could not install (\(error.localizedDescription)) — run:")
            Sevo.printError("  sudo ln -sf '\(source.path)' \(target.path)")
            throw SevoExit.failed
        }
    }
}

struct VersionCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "version", abstract: "Print the sevo version.",
    )

    func run() async throws {
        print("sevo \(Sevo.version)")
    }
}
