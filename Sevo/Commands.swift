import ArgumentParser
import Foundation
import os

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
            DoctorCommand.self, StatusCommand.self, SetupCommand.self,
            EngineCommand.self, BottleCommand.self, StorageCommand.self,
            ClientCommand.self, RecoverCommand.self,
            AppCommand.self, DownloadsCommand.self,
            EvalCommand.self, BenchmarkCommand.self, CDPCommand.self, LogsCommand.self,
            RunCommand.self,
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
        // The engine in use, which is a choice, and only "NONE" when there is
        // nothing on disk to choose from.
        let engine = if d.crossover == nil, d.managedEngineVersions.isEmpty {
            "NONE"
        } else if case .crossover = Engine.active, let cx = d.crossover {
            "CrossOver \(cx.version)"
        } else {
            Engine.active.description
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

// MARK: - setup

struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Headless onboarding: engine, bottle, Steam client.",
        discussion: "Runs the same provisioning state machine as the app's "
            + "first-run assistant, so the two cannot drift. Every stage is "
            + "idempotent — anything already present is kept, and an "
            + "interrupted run continues where it left off.",
    )

    @Option(
        name: .customLong("engine"),
        help: "builtin | crossover. Default: CrossOver when usable, else built-in.",
    ) var engine: String?
    @Option(
        name: .customLong("manifest"),
        help: "Manifest URL override, for installing the built-in engine offline.",
    ) var manifest: String?

    func run() async throws {
        try await provision()
    }

    @MainActor
    private func provision() async throws {
        if let manifest {
            guard let url = URL(string: manifest) else {
                Sevo.printError("not a URL: \(manifest)")
                throw SevoExit.badInvocation
            }
            EngineManifest.overrideURL = url
        }
        let provisioner = Provisioner()
        await provisioner.refreshDetection()
        guard let detection = provisioner.detection else {
            Sevo.printError("detection failed")
            throw SevoExit.failed
        }
        Engine.active = try resolveEngine(from: detection)
        guard provisioner.needsSetup else {
            print("already provisioned — engine \(Engine.active.description), "
                + "Steam in bottle '\(SteamBottle.name)'")
            return
        }
        await provisioner.provisionAndConfigure()
        switch provisioner.activity {
        case .done:
            print("setup complete — engine \(Engine.active.description), "
                + "Steam in bottle '\(SteamBottle.name)'")
        case let .failed(reason):
            Sevo.printError("setup failed: \(reason)")
            throw SevoExit.failed
        default:
            Sevo.printError("setup ended in an unexpected state")
            throw SevoExit.failed
        }
    }

    /// `--engine` is a deliberate override of the detection default, so an
    /// impossible choice is an error rather than a silent fallback.
    private func resolveEngine(from detection: SetupDetection) throws -> Engine {
        switch engine {
        case nil:
            return Engine.resolve(from: detection)
        case "crossover":
            guard detection.usableCrossOver != nil else {
                Sevo.printError("no usable CrossOver on this machine")
                throw SevoExit.notProvisioned
            }
            return .crossover
        case "builtin":
            guard let version = detection.managedEngineVersions.last else {
                Sevo.printError("no built-in engine installed — run: sevo engine install")
                throw SevoExit.notProvisioned
            }
            return .managed(version: version)
        default:
            Sevo.printError("--engine must be builtin or crossover")
            throw SevoExit.badInvocation
        }
    }
}

// MARK: - storage

struct StorageCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "storage",
        abstract: "What Sevoflurane and its bottle occupy on disk.",
    )

    @Flag(name: .customLong("games"), help: "List installed games instead of the summary.")
    var listGames = false
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        if listGames {
            let games = StorageInventory.installedGames()
            if asJSON {
                let rows = games.map {
                    #"{"appid":\#($0.id),"name":\#(JSLiteral.string($0.name)),"bytes":\#($0.bytes)}"#
                }
                print("[\(rows.joined(separator: ","))]")
                return
            }
            for game in games {
                print("\(Self.size(game.bytes).padded(to: 10))  \(game.name)")
            }
            return
        }
        var sized: [(StorageInventory.Entry, Int64)] = []
        for entry in StorageInventory.entries() {
            await sized.append((entry, StorageInventory.size(of: entry)))
        }
        if asJSON {
            let rows = sized.map {
                #"{"id":\#(JSLiteral.string($0.0.id)),"bytes":\#($0.1)}"#
            }
            print("[\(rows.joined(separator: ","))]")
            return
        }
        for (entry, bytes) in sized where bytes > 0 {
            print("\(Self.size(bytes).padded(to: 10))  \(entry.name)")
        }
        print("\(Self.size(sized.map(\.1).reduce(0, +)).padded(to: 10))  total")
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

private extension String {
    func padded(to width: Int) -> String {
        count >= width ? self : String(repeating: " ", count: width - count) + self
    }
}

// MARK: - engine / bottle

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Wine engines (CrossOver, managed OSS).",
    )

    @Argument(help: "list | install | d3dmetal") var verb: String = "list"
    @Option(
        name: .customLong("from"),
        help: "For d3dmetal: Apple's Game Porting Toolkit disk image, volume, or folder.",
    ) var from: String?
    @Option(
        name: .customLong("use"),
        help: "For d3dmetal: the version to run, or 'own' for the engine's own copy.",
    ) var use: String?
    @Option(
        name: .customLong("into"),
        help: "For d3dmetal: which installed engine to add it to (default: the active one).",
    ) var into: String?
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
        case "d3dmetal":
            try await addD3DMetal()
        default:
            Sevo.printError("engine \(verb): unknown verb (list | install | d3dmetal)")
            throw SevoExit.badInvocation
        }
    }

    /// Adds Apple's D3DMetal to the managed engine from the user's own copy
    /// of the Game Porting Toolkit — the CLI face of Settings › Graphics.
    private func addD3DMetal() async throws {
        // Without `--into`, the toolkit goes wherever this engine keeps it:
        // inside a managed engine, or the shared store that CrossOver is
        // pointed at through the shadow tree.
        var version = into
        if version == nil, case let .managed(active) = Engine.active { version = active }
        let engine = version.map(Engine.managedRoot.appendingPathComponent)
            ?? D3DMetalInstaller.sharedRoot
        let label = version ?? "CrossOver"
        if let use {
            if use == "own" {
                D3DMetalInstaller.choose(version: nil)
            } else {
                guard let entry = D3DMetalInstaller.installed(inEngine: engine)
                    .first(where: { $0.version == use })
                else {
                    Sevo.printError("D3DMetal \(use) is not installed for \(label)")
                    throw SevoExit.badInvocation
                }
                // Placed in the Wine tree now, not at the next boot: choosing
                // is the moment the user is waiting on this, not the moment a
                // game is.
                try D3DMetalInstaller.activate(entry, inEngine: engine)
            }
            let launcher = CrossOverShadow.preparedLauncher()
            print("D3DMetal for \(label): \(use == "own" ? "the engine's own" : use)"
                + (launcher == nil ? "" : " (shadow tree ready)"))
            return
        }
        guard let from else {
            let installed = D3DMetalInstaller.installed(inEngine: engine)
            let active = D3DMetalInstaller.active(inEngine: engine)
            if installed.isEmpty {
                print("no D3DMetal installed for \(label) — add one with: "
                    + "sevo engine d3dmetal --from <Game Porting Toolkit dmg>")
            }
            for entry in installed {
                var notes: [String] = []
                if entry == active { notes.append("active") }
                if version != nil, D3DMetalInstaller.isPlaced(entry, inEngine: engine) {
                    notes.append("in the Wine tree")
                }
                print(entry.version + (notes.isEmpty ? "" : "  (\(notes.joined(separator: ", ")))"))
            }
            if active == nil, !installed.isEmpty { print("the engine's own  (active)") }
            return
        }
        do {
            let entry = try await D3DMetalInstaller.install(
                from: URL(fileURLWithPath: (from as NSString).expandingTildeInPath),
                intoEngine: engine,
            )
            print("D3DMetal \(entry.version) installed for \(label)")
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
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
            let printed = OSAllocatedUnfairLock(initialState: "")
            try await EngineInstaller.install(release) { phase, _ in
                let repeated = printed.withLock { last in
                    defer { last = phase }
                    return last == phase
                }
                guard !repeated else { return }
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
    @Argument(help: "Config key: renderer | msync | wine-debug. Omit to print every key.")
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
                    "wine-debug": WineLog.channels,
                ], pretty: true))
            } else {
                print("renderer \(selection.renderer.rawValue)")
                print("msync \(selection.msync)")
                print("wine-debug \(WineLog.channels)")
            }
            return
        }
        guard let value else {
            switch key {
            case "renderer": print(selection.renderer.rawValue)
            case "msync": print(selection.msync)
            case "wine-debug": print(WineLog.channels)
            default:
                Sevo.printError("unknown key '\(key)' (renderer | msync | wine-debug)")
                throw SevoExit.badInvocation
            }
            return
        }
        if key == "wine-debug" {
            // Wine's own channel syntax, e.g. `+seh,+loaddll` or
            // `-all,err+all`; `off` is the quiet default. Read by the next
            // client start, and inherited by every game it launches.
            WineLog.setChannels(value == "off" ? nil : value)
            print("wine-debug \(WineLog.channels) — takes effect at the next client start; "
                + "trail at \(WineLog.fileURL.path)")
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
            Sevo.printError("unknown key '\(key)' (renderer | msync | wine-debug)")
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
        Engine.active.isCrossOver
            ? BottleGraphics.selection(forBottle: SteamBottle.root)
            : BottleGraphics.managedSelection()
    }

    private func apply(_ selection: BottleGraphics.Selection) throws {
        switch Engine.active {
        case .crossover, .crossoverPreview:
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

struct BenchmarkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "benchmark",
        abstract: "Run Sevoflurane's opt-in Library, Store, and Friends profile scenario.",
    )

    @Option(name: .long, help: "Warm iterations per target (1...10).") var iterations = 5
    @Option(name: .long, help: "One target: library, store, or friends.") var target: String?
    @Option(
        name: .long,
        help: "Busy threads standing in for a running game while the scenario is timed.",
    ) var load = 0
    @Option(
        name: .long,
        help: "Scheduling class of the load threads: background, utility, default, or userInitiated.",
    ) var qos = "default"

    func run() async throws {
        let count = min(max(iterations, 1), 10)
        if let target, !["library", "store", "friends"].contains(target) {
            Sevo.printError("benchmark target must be library, store, or friends")
            throw SevoExit.badInvocation
        }
        guard ["background", "utility", "default", "userInitiated"].contains(qos) else {
            Sevo.printError("qos must be background, utility, default, or userInitiated")
            throw SevoExit.badInvocation
        }
        let path = "/benchmark/smoke?iterations=\(count)&load=\(max(load, 0))&qos=\(qos)"
            + (target.map { "&target=\($0)" } ?? "")
        // Worst case is every step timing out: three targets, 12 s each,
        // plus the run's own setup.
        let timeout = TimeInterval(30 + count * (target == nil ? 3 : 1) * 15)
        guard let reply = await AppControl.postReply(path, timeout: timeout) else {
            Sevo.printError("benchmark unavailable — is Sevoflurane running?")
            throw SevoExit.unreachable
        }
        let text = String(decoding: reply.body, as: UTF8.self)
        guard (200 ..< 300).contains(reply.status) else {
            Sevo.printError(
                reply.status == 403
                    ? "benchmarks are off — launch Sevoflurane with SEVO_ENABLE_BENCHMARKS=1"
                    : "benchmark failed (\(reply.status)): \(text)",
            )
            throw SevoExit.unreachable
        }
        print(text)
    }
}

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

/// Runs one Windows program in the bottle under the engine a game would get.
///
/// The launcher path for everything that is not the client: a game's own exe
/// when Steam refuses to start it, a harness, `winecfg`. Steam's updater
/// gates a launch on free disk space it may not have, and this reaches the
/// installed build regardless — with the client up, the game still finds
/// SteamAPI.
struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Run a Windows program in the bottle (debug launcher; never the client).",
        discussion: """
        The program is a Unix or Windows path. Wine's own output goes to the \
        terminal and to the wine trail (sevo logs --wine); set its channels \
        with sevo bottle config wine-debug.
        """,
    )

    @Argument(parsing: .captureForPassthrough, help: "The program, then its arguments.")
    var program: [String] = []

    @Flag(name: .customLong("wait"), help: "Stay until the program and its children exit.")
    var wait = false

    func run() async throws {
        guard let first = program.first else {
            Sevo.printError("nothing to run")
            throw SevoExit.badInvocation
        }
        // The client has a lifecycle with a restart ladder and a supervisor
        // that owns it; a second launcher racing that is how a bottle ends up
        // with two clients.
        guard !first.lowercased().hasSuffix("steam.exe") else {
            Sevo.printError("the client is the supervisor's to start — use sevo client start")
            throw SevoExit.badInvocation
        }
        let invocation = Engine.active.wineInvocation(
            bottle: SteamBottle.name,
            wait: wait ? .children : .none,
            program: program,
        )
        let process = Process()
        process.executableURL = invocation.executable
        process.arguments = invocation.arguments
        if let environment = invocation.environment { process.environment = environment }
        do {
            try process.run()
        } catch {
            Sevo.printError("could not start \(first): \(error.localizedDescription)")
            throw SevoExit.failed
        }
        print("started \(first) under \(Engine.active)")
        guard wait else { return }
        process.waitUntilExit()
        print("\(first) exited (status \(process.terminationStatus))")
        if process.terminationStatus != 0 { throw SevoExit.failed }
    }
}

struct LogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "The unified event log.",
    )
    @Option(name: .customLong("tail")) var tail: Int = 50
    @Flag(name: .shortAndLong) var follow = false
    @Flag(
        name: .customLong("wine"),
        help: "Wine's own stderr for managed launches (client, games) instead of the event log.",
    ) var wine = false

    func run() async throws {
        try await Self.tail(lines: tail, follow: follow, file: wine ? WineLog.fileURL : Sevo.logFile)
    }

    static func tail(lines: Int, follow: Bool, file: URL = Sevo.logFile) async throws {
        guard let handle = try? FileHandle(forReadingFrom: file) else {
            Sevo.printError("no log file at \(file.path) — has the app ever run?")
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
