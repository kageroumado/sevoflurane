import ArgumentParser
import Foundation
import os
import Synchronization

/// `sevo` — one management surface, three consumers: us (testing and
/// debugging), terminal-comfortable end users, and AI agents (via `sevo mcp`
/// or by just running the CLI).
@main
struct SevoCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sevo",
        abstract: "Manage Sevoflurane's bottled Steam client.",
        version: Sevo.version,
        subcommands: [
            DoctorCommand.self, StatusCommand.self, WaitCommand.self, SetupCommand.self,
            EngineCommand.self, UpdateCommand.self, ShadersCommand.self, BottleCommand.self,
            StorageCommand.self,
            ClientCommand.self, RecoverCommand.self, DaemonCommand.self,
            AppCommand.self, ProgramCommand.self, NWJSCommand.self, DownloadsCommand.self,
            EvalCommand.self, BenchmarkCommand.self, CDPCommand.self, LogsCommand.self,
            RunsCommand.self, DiagCommand.self, DebugCommand.self,
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
        case let .unanswered(detail):
            Sevo.printError("client too busy to answer: \(detail) — try again shortly")
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

/// The one observation every mutating verb ends on and `status` prints alone:
/// engine, bottle, client, bridge, app, as a line and as a dict. The verbs
/// carry it as `state` so the reply is what actually happened, not that it was
/// asked for.
enum StatusReport {
    static func build() async -> (dict: [String: Any], line: String) {
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
        case .busy: "running, CDP too busy to answer"
        case .down: snapshot.bottleProcesses.isEmpty ? "stopped" : "up, CDP unreachable"
        }
        // Two processes, two answers: supervision is the daemon that owns the
        // bottle, and the app is the window onto it. Either can be down while
        // the other works.
        let supervision = if let status = snapshot.appStatus {
            "running (\(status["health"] as? String ?? "?"))"
        } else {
            "not running"
        }
        // Supervision above is the daemon; this is the app process. The daemon
        // sees only an attached app, so a live-but-detached one is read off its
        // own link port instead of inheriting the daemon's blind spot.
        let appState = AppRunState.classify(
            daemonReportsAttached: (snapshot.appStatus?["app"] as? String) == "running",
            appLinkAlive: snapshot.appLinkAlive,
        )
        // A bottle missing a required dependency still runs games, so this is
        // a note beside the client's state rather than a state of its own.
        let incomplete = BottleReadiness.incompleteSummary()
        let dict: [String: Any] = [
            "engine": engine,
            "bottle": SteamBottle.name,
            "steam_installed": steamOK,
            "bottle_incomplete": incomplete ?? NSNull(),
            "provisioning": snapshot.provision?.dictionary ?? NSNull(),
            "client": client,
            "services_up": snapshot.servicesUp ?? NSNull(),
            "bridge": snapshot.bridgeUp,
            "app": snapshot.appStatus ?? NSNull(),
            "app_running": appState.isRunning,
            "app_attached": appState == .attached,
            "dump_rate_10m": snapshot.dumpCount,
            "client_pinned": snapshot.pinned,
        ]
        var line = "engine \(engine) · bottle \(SteamBottle.name) (\(steamOK ? "steam ok" : "no steam"))"
            + " · client \(client) · bridge \(snapshot.bridgeUp ? "up" : "down")"
            + " · supervision \(supervision) · app \(appState.rawValue)"
        if let incomplete { line += " · bottle incomplete (\(incomplete))" }
        if snapshot.appStatus?["debug"] as? Bool == true { line += " · debug mode on" }
        return (dict, line)
    }

    /// Prints a verb's outcome the way `sevo client force-quit` prints its
    /// own: the verdict, then the state the caller's model should hold now.
    static func emit(_ outcome: ClientOps.Outcome, asJSON: Bool) async {
        let (dict, line) = await build()
        if asJSON {
            print(Sevo.json([
                "verdict": outcome.verdict.rawValue,
                "intent": outcome.intent,
                "note": outcome.note,
                "state": dict,
            ], pretty: true))
        } else {
            print("\(outcome.intent): \(outcome.verdict.rawValue) — \(outcome.note)")
            print("  \(line)")
        }
    }
}

/// The game window a launch produced, as an agent reads it: id, title, pid,
/// and the frame twice — points (the click/move coordinate) and pixels (what a
/// screenshot measures) — plus the Retina scale and which display, so a
/// negative origin on a second display is legible rather than a surprise.
enum WindowReport {
    /// The game window the app reports right now, if any.
    static func currentWindow() async -> [String: Any]? {
        guard let data = await AppControl.get("/game/window"),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["window_id"] != nil else { return nil }
        return obj
    }

    /// Polls the app for the launched game's window until it appears or the
    /// timeout; `nil` when none showed (or the app is not running to observe
    /// it). A window that was already up before the launch, or one owned by
    /// an exe the store knows belongs to another game, is not this launch's.
    static func awaitWindow(
        forApp appid: Int, before: [String: Any]?, timeout: Int, progress: (String) -> Void,
    ) async -> [String: Any]? {
        let known = GameConfig.game(appid).exes ?? []
        for waited in stride(from: 0, through: timeout, by: 3) {
            if let obj = await currentWindow() {
                let owner = (obj["owner"] as? String ?? "").lowercased()
                let isNew = obj["window_id"] as? Int != before?["window_id"] as? Int
                // With no exe recorded yet, any new window looks like this
                // launch's — including a window another game just put up.
                let claimant = GameConfig.app(claiming: owner)
                let accepted = known.isEmpty
                    ? (isNew && (claimant == nil || claimant == appid))
                    : known.contains(owner)
                if accepted { return obj }
            }
            try? await Task.sleep(for: .seconds(3))
            if waited > 0, waited % 15 == 0 { progress("waiting for the game window (\(waited)s)") }
        }
        return nil
    }

    static func lines(_ w: [String: Any]) -> [String] {
        func frame(_ d: [String: Any]?) -> String {
            guard let d, let x = d["x"] as? Double, let y = d["y"] as? Double,
                  let width = d["w"] as? Double, let height = d["h"] as? Double else { return "?" }
            return String(format: "%.0f,%.0f %.0f×%.0f", x, y, width, height)
        }
        let scale = w["retina_scale"] as? Double ?? 0
        let display = w["display"] as? [String: Any]
        let offPrimary = w["off_primary"] as? Bool == true
        return [
            "window \(w["window_id"] as? Int ?? 0) · \(w["owner"] as? String ?? "?") · pid \(w["pid"] as? Int ?? 0)",
            "title: \(w["title"] as? String ?? "")",
            "frame: \(frame(w["frame_points"] as? [String: Any])) pts · "
                + "\(frame(w["frame_pixels"] as? [String: Any])) px · scale \(String(format: "%g", scale))",
            "display \(display?["index"] as? Int ?? 0)"
                + (offPrimary ? " · off primary (negative origin)" : ""),
        ]
    }
}

/// Live narration during a wait. In `--json` it goes to stderr so stdout
/// stays a single clean observation; otherwise it prints inline.
func narrate(_ line: String, asJSON: Bool) {
    if asJSON {
        FileHandle.standardError.write(Data((line + "\n").utf8))
    } else {
        print(line)
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "One line: engine, bottle, client, bridge, supervision, app.",
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let (dict, line) = await StatusReport.build()
        print(asJSON ? Sevo.json(dict, pretty: true) : line)
    }
}

/// Block until the client reaches a state, then report it — the time-holding
/// verb. Default waits for healthy; `--gone`
/// waits for it to be down. Either way the reply is the observed end state
/// plus a verdict, never a bare "ok".
struct WaitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wait",
        abstract: "Block until the client is healthy (or --gone: down), then report.",
    )
    @Flag(name: .customLong("gone"), help: "Wait for the client to be gone, not healthy.")
    var gone = false
    @Option(name: .customLong("timeout"), help: "Seconds to wait (default 120).")
    var timeout = 120
    @Flag(name: .customLong("no-app")) var noApp = false
    @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

    func run() async throws {
        let sink = { narrate($0, asJSON: asJSON) }
        let outcome: ClientOps.Outcome = if gone {
            await ClientOps.waitGone(timeout: timeout, progress: sink)
        } else if await ClientOps.supervisionIsRunning(noApp: noApp) {
            await ClientOps.pollAppHealthy(intent: "wait", timeout: timeout, progress: sink)
        } else {
            await ClientOps.pollClientUp(intent: "wait", timeout: timeout, progress: sink)
        }
        await StatusReport.emit(outcome, asJSON: asJSON)
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
        abstract: "Wine engines: Dormison releases and CrossOver.",
    )

    @Argument(help: "list | install [--file TARBALL-OR-FOLDER] | d3dmetal | use | channel [stable|beta] | check-manifest")
    var verb: String = "list"
    @Argument(
        help: "For use: the engine to switch to (a name from `sevo engine list`); for channel: stable or beta; for check-manifest: the engine.json to check.",
    )
    var target: String?
    @Option(
        name: .customLong("channel"),
        help: "For install: take this channel's release instead of the Mac's setting (stable | beta).",
    ) var channelName: String?

    private func channel() throws -> EngineChannel? {
        guard let channelName else { return nil }
        guard let channel = EngineChannel(rawValue: channelName) else {
            Sevo.printError("--channel \(channelName): stable or beta")
            throw SevoExit.badInvocation
        }
        return channel
    }
    @Option(
        name: .customLong("sig"),
        help: "For check-manifest: the engine.json.sig to verify against the pinned key.",
    ) var signatureFile: String?
    @Option(
        name: .customLong("bottle"),
        help: "For use: the bottle to run (default: the current one).",
    ) var bottle: String?
    @Flag(
        name: .customLong("no-app"),
        help: "For use: drive the client from this process instead of through the app (debug); without it a closed app is opened to boot the engine.",
    ) var noApp = false
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
    @Option(
        name: .customLong("file"),
        help: "For install: an engine tarball (dormison-r<N>.tar.xz) or an engine folder on disk, in place of the download; a .sig beside a tarball is verified.",
    ) var file: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "install":
            try await install()
        case "d3dmetal":
            try await addD3DMetal()
        case "use":
            try await use()
        case "channel":
            try setChannel()
        case "check-manifest":
            try checkManifest()
        default:
            Sevo.printError("engine \(verb): unknown verb (list | install | d3dmetal | use | channel | check-manifest)")
            throw SevoExit.badInvocation
        }
    }

    /// Reads or sets which channel this Mac takes engines from. The next
    /// install and the next update check read it; nothing already installed
    /// changes.
    private func setChannel() throws {
        if let target {
            guard let channel = EngineChannel(rawValue: target) else {
                Sevo.printError("engine channel \(target): stable or beta")
                throw SevoExit.badInvocation
            }
            Preferences.engineChannel = channel
            print("engine channel: \(channel.rawValue) — the next install and update check take it")
        } else {
            print("engine channel: \(Preferences.engineChannel.rawValue)")
        }
    }

    /// The gate `publish-engine.sh` runs before it uploads a manifest: the
    /// file decodes with this build's decoder, every entry passes
    /// ``EngineManifest/problems()``, and with `--sig` the bytes verify
    /// against the key pinned in ``EngineSignature``. Exit 1 on any problem.
    private func checkManifest() throws {
        guard let target, !target.isEmpty else {
            Sevo.printError("engine check-manifest: name the engine.json to check")
            throw SevoExit.badInvocation
        }
        let path = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        var problems: [String] = []
        var summary: [String: Any] = ["file": path.path]
        do {
            let data = try Data(contentsOf: path)
            let manifest = try EngineManifest.decode(data)
            problems = manifest.problems()
            summary["schema"] = manifest.schema
            summary["channels"] = manifest.channels.mapValues { $0.version }
            summary["components"] = (manifest.components ?? [:]).mapValues(\.count)
            summary["shaders"] = manifest.shaders?.count ?? 0
            if let signatureFile {
                let sigPath = (signatureFile as NSString).expandingTildeInPath
                do {
                    try EngineSignature.verify(
                        data, signatureFile: Data(contentsOf: URL(fileURLWithPath: sigPath)),
                        subject: path.lastPathComponent,
                    )
                    summary["signature"] = "verified"
                } catch {
                    problems.append("signature: \(error)")
                }
            }
        } catch {
            problems.append("decode: \(error)")
        }
        summary["problems"] = problems
        if asJSON {
            print(Sevo.json(summary, pretty: true))
        } else if problems.isEmpty {
            let channels = (summary["channels"] as? [String: String] ?? [:])
                .sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }.joined(separator: ", ")
            print("manifest ok: schema \(summary["schema"] ?? "?"), \(channels)"
                + ((summary["signature"] as? String).map { ", signature \($0)" } ?? ""))
        } else {
            for problem in problems {
                Sevo.printError("manifest: \(problem)")
            }
        }
        if !problems.isEmpty { throw SevoExit.failed }
    }

    /// Switches the active engine and restarts the client — the CLI face of
    /// Settings › Engine's picker plus Apply.
    private func use() async throws {
        guard let target, !target.isEmpty else {
            Sevo.printError("engine use: name the engine to switch to (sevo engine list)")
            throw SevoExit.badInvocation
        }
        let engine: Engine = switch target {
        case "crossover": .crossover
        case "crossover-preview": .crossoverPreview
        default: .managed(version: target)
        }
        guard engine.existsOnDisk else {
            Sevo.printError("engine \(target) is not installed — sevo engine list")
            throw SevoExit.badInvocation
        }
        try await handlingFailures {
            let outcome = try await ClientOps.useEngine(
                engine, version: target, bottle: bottle, noApp: noApp,
            ) { narrate($0, asJSON: asJSON) }
            await StatusReport.emit(outcome, asJSON: asJSON)
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
                // Record only: the next spawn stages both halves together
                // (``EngineRenderers/stage``). Placing the macOS half here
                // while the Windows half waits crosses versions.
                D3DMetalInstaller.choose(version: entry.version)
            }
            let launcher = CrossOverShadow.preparedLauncher()
            // Games spawn inside the client, which staged its toolkit when it
            // booted: the choice reaches them with the client's next boot.
            print("D3DMetal for \(label): \(use == "own" ? "the engine's own" : use)"
                + (launcher == nil ? "" : ", shadow tree ready")
                + " — in the client from its next boot: sevo client restart")
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
                let note = entry == active ? "  (selected)" : ""
                print(entry.version + note)
            }
            if active == nil, !installed.isEmpty { print("the engine's own  (selected)") }
            // The on-disk truth: what a game actually loads, both halves,
            // independent of what the picker recorded. A crossed tree here is
            // the silent 14 s boot death.
            if version != nil, !installed.isEmpty {
                let placement = D3DMetalInstaller.placement(inEngine: engine)
                if let macOS = placement.macOS, placement.halvesAgree {
                    print("in the Wine tree: \(macOS)  (both halves)")
                } else if placement.macOS != nil || placement.windows != nil {
                    print("⚠ crossed tree: macOS half "
                        + "\(placement.macOS ?? "none"), Windows half "
                        + "\(placement.windows ?? "none") — start a game to restage")
                } else {
                    print("in the Wine tree: none yet (staged at the next launch)")
                }
            }
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
    /// of the wizard's built-in-engine stage — or, with `--file`, installs
    /// the tarball or engine folder on disk, the route for a Mac the release
    /// feed does not reach and for a tree built here.
    private func install() async throws {
        if let file {
            let source = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            do {
                let version = try await EngineInstaller.install(from: source, progress: phasePrinter())
                print("engine \(version) installed")
            } catch {
                Sevo.printError("engine install failed: \(error)")
                throw SevoExit.failed
            }
            return
        }
        let manifestURL = try manifest.map {
            guard let url = URL(string: $0) else {
                Sevo.printError("not a URL: \($0)")
                throw SevoExit.badInvocation
            }
            return url
        } ?? EngineManifest.url
        do {
            let fetched = try await EngineManifest.fetch(from: manifestURL)
            guard let release = fetched.release(for: try channel() ?? Preferences.engineChannel) else {
                Sevo.printError("manifest has no stable channel")
                throw SevoExit.failed
            }
            guard !EngineInstaller.isInstalled(release) else {
                print("engine \(release.version) already installed")
                return
            }
            try await EngineInstaller.install(release, progress: phasePrinter())
            print("engine \(release.version) installed")
        } catch let code as ExitCode {
            throw code
        } catch {
            Sevo.printError("engine install failed: \(error)")
            Sevo.printError("with the tarball on disk: sevo engine install --file dormison-r<N>.tar.xz")
            throw SevoExit.failed
        }
    }

    /// Each new install phase once, on stderr; the fraction is not shown.
    private func phasePrinter() -> @Sendable (String, Double?) -> Void {
        let printed = OSAllocatedUnfairLock(initialState: "")
        return { phase, _ in
            let repeated = printed.withLock { last in
                defer { last = phase }
                return last == phase
            }
            guard !repeated else { return }
            FileHandle.standardError.write(Data((phase + "\n").utf8))
        }
    }

    private func list() async throws {
        let d = await SetupProbe.detect()
        var rows: [[String: Any]] = []
        for (name, cx) in [("crossover", d.crossover), ("crossover-preview", d.crossoverPreview)] {
            guard let cx else { continue }
            rows.append([
                "engine": name, "version": cx.version, "licensed": cx.licensed,
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

/// Versions of what runs under the app: the renderers beside the engine's
/// own. The CLI face of Settings › Graphics › Renderer versions.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for and switch renderer versions (DXMT, DXVK).",
        discussion: """
        check              what is installed, chosen and available for each renderer
        use <c> <version>  run that version from the next boot; 'default' resets to the engine's own
        install <c> <ref>  add a version: a release version from check, a URL, an archive, or a folder
        remove <c> <version>
        <c> is dxmt or dxvk.
        """,
    )

    @Argument(help: "check | use | install | remove") var verb: String = "check"
    @Argument var component: String?
    @Argument var reference: String?
    @Option(help: "For install: the version to file it under when it cannot be read from the name.")
    var version: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "check": try await check()
        case "use": try await use()
        case "install": try await install()
        case "remove": try remove()
        default:
            Sevo.printError("update \(verb): unknown verb (check | use | install | remove)")
            throw SevoExit.badInvocation
        }
    }

    private func resolveComponent() throws -> RendererVersions.Component {
        guard let component, let resolved = RendererVersions.Component(rawValue: component.lowercased()) else {
            Sevo.printError("name the renderer: dxmt or dxvk")
            throw SevoExit.badInvocation
        }
        return resolved
    }

    private func check() async throws {
        let manifest = try? await EngineManifest.fetch()
        let engine = Engine.active.root
        var report: [[String: Any]] = []
        for component in RendererVersions.Component.allCases {
            let installed = RendererVersions.installed(component).map(\.version)
            let chosen = RendererVersions.chosen(component)
            let defaultVersion = RendererVersions.defaultVersion(component, engine: engine)
            let releases = await RendererVersions.releases(component, manifest: manifest)
            let newer = RendererVersions.newerRelease(than: installed, default: defaultVersion, among: releases)
            report.append([
                "component": component.rawValue,
                "default": defaultVersion ?? NSNull(),
                "chosen": chosen ?? NSNull(),
                "installed": installed,
                "available": releases.map { ["version": $0.version, "tested": $0.tested, "url": $0.url.absoluteString] },
                "newer": newer?.version ?? NSNull(),
            ])
            if !asJSON {
                print("\(component.label)")
                print("  running:   \(chosen ?? "engine's own\(defaultVersion.map { " (\($0))" } ?? "")")")
                print("  installed: \(installed.isEmpty ? "none added" : installed.joined(separator: ", "))")
                let available = releases.map { "\($0.version)\($0.tested ? " (tested)" : "")" }
                print("  available: \(available.isEmpty ? "unknown — no release list reachable" : available.joined(separator: ", "))")
                if let newer { print("  newer:     \(newer.version)\(newer.tested ? ", tested with this engine" : ", untested")") }
            }
        }
        if asJSON {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private func use() async throws {
        let component = try resolveComponent()
        guard let reference else {
            Sevo.printError("update use: name a version, or 'default'")
            throw SevoExit.badInvocation
        }
        if reference == "default" {
            RendererVersions.choose(component, version: nil)
            print("\(component.label): the engine's own, from the next Steam start")
            return
        }
        guard RendererVersions.installed(component).contains(where: { $0.version == reference }) else {
            Sevo.printError("\(component.label) \(reference) is not installed — sevo update install \(component.rawValue) \(reference)")
            throw SevoExit.badInvocation
        }
        RendererVersions.choose(component, version: reference)
        print("\(component.label): \(reference), from the next Steam start")
    }

    private func install() async throws {
        let component = try resolveComponent()
        guard let reference else {
            Sevo.printError("update install: a version from `sevo update check`, a URL, an archive, or a folder")
            throw SevoExit.badInvocation
        }
        var source: URL
        var sha256: String?
        var name = version
        if reference.hasPrefix("http://") || reference.hasPrefix("https://"), let url = URL(string: reference) {
            source = url
        } else if FileManager.default.fileExists(atPath: reference) {
            source = URL(fileURLWithPath: reference)
        } else {
            let manifest = try? await EngineManifest.fetch()
            let releases = await RendererVersions.releases(component, manifest: manifest)
            guard let release = releases.first(where: { $0.version == reference }) else {
                Sevo.printError("no \(component.label) release \(reference) — sevo update check lists them")
                throw SevoExit.badInvocation
            }
            source = release.url
            sha256 = release.sha256
            name = name ?? release.version
        }
        let entry = try await RendererVersions.install(component, from: source, version: name, sha256: sha256)
        RendererVersions.choose(component, version: entry.version)
        print("\(component.label) \(entry.version) installed at \(entry.root.path) and chosen for the next Steam start")
    }

    private func remove() throws {
        let component = try resolveComponent()
        guard let reference,
              let entry = RendererVersions.installed(component).first(where: { $0.version == reference }) else {
            Sevo.printError("update remove: name an installed version (sevo update check)")
            throw SevoExit.badInvocation
        }
        try RendererVersions.remove(entry)
        print("\(component.label) \(reference) moved to the Trash")
    }
}

/// The switches that are one env key each, by the name the command line
/// calls them. One table, so the two config commands, their help and their
/// JSON cannot name different sets.
enum ConfigSwitches {
    struct Entry: Sendable {
        let key: String
        let path: WritableKeyPath<ConfigValues, Bool?> & Sendable
    }

    static let all: [Entry] = [
        Entry(key: "hud", path: \.hud),
        Entry(key: "fps", path: \.fps),
        Entry(key: "cursor-confine", path: \.cursorConfine),
        Entry(key: "avx", path: \.avx),
        Entry(key: "large-address-aware", path: \.largeAddressAware),
    ]

    static var names: String {
        all.map(\.key).joined(separator: " | ")
    }

    static func path(for key: String) -> (WritableKeyPath<ConfigValues, Bool?> & Sendable)? {
        all.first { $0.key == key }?.path
    }

    /// The resolved value and the level it came from, for a game when its id
    /// is known and for the bottle otherwise.
    static func resolved(_ key: String, bottle: String, game appID: Int?) -> Resolved<Bool>? {
        switch key {
        case "hud": GameConfig.hud(bottle: bottle, game: appID)
        case "fps": GameConfig.fps(bottle: bottle, game: appID)
        case "cursor-confine": GameConfig.cursorConfine(bottle: bottle, game: appID)
        case "avx": GameConfig.avx(bottle: bottle, game: appID)
        case "large-address-aware": GameConfig.largeAddressAware(bottle: bottle, game: appID)
        default: nil
        }
    }

    /// What a switch costs beyond the next launch, where it costs anything.
    static func caveat(_ key: String) -> String? {
        key == "large-address-aware" ? "needs Dormison r14 or later" : nil
    }
}

/// The values `sevo bottle config` and `sevo app config` accept for the keys
/// the settings hierarchy resolves; `inherit` clears the level.
enum ConfigKeyParsing {
    static func windows(_ value: String) throws -> WindowTreatment? {
        if value == "inherit" { return nil }
        guard let treatment = WindowTreatment(rawValue: value) else {
            Sevo.printError("windows must be \(WindowTreatment.help)")
            throw SevoExit.badInvocation
        }
        return treatment
    }

    static func mouse(_ value: String) throws -> MouseCurve? {
        if value == "inherit" { return nil }
        guard let curve = MouseCurve(rawValue: value) else {
            Sevo.printError("mouse must be system, linear or inherit")
            throw SevoExit.badInvocation
        }
        return curve
    }

    /// A switch: on, off, or the level-clearing value.
    static func flag(_ value: String, key: String) throws -> Bool? {
        switch value {
        case "inherit": nil
        case "on", "true", "yes": true
        case "off", "false", "no": false
        default:
            Sevo.printError("\(key) must be on, off or inherit")
            throw SevoExit.badInvocation
        }
    }

    /// One `<dll>=<mode>` pair for a game's own load order, `<dll>=` to drop
    /// the entry, or `inherit` to drop the whole table. The modes are Wine's
    /// own spelling, so what is typed is what the registry holds.
    static let overrideModes = ["n,b", "b,n", "n", "b", ""]

    static func dllOverride(_ value: String) throws -> (dll: String, mode: String?)? {
        if value == "inherit" { return nil }
        let parts = value.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty else {
            Sevo.printError("dll takes <name>=<mode>, <name>= to drop one, or inherit; "
                + "mode is one of n,b | b,n | n | b | \"\" (disabled)")
            throw SevoExit.badInvocation
        }
        let dll = String(parts[0]).lowercased()
        let mode = String(parts[1])
        if mode.isEmpty { return (dll, nil) }
        guard overrideModes.contains(mode) else {
            Sevo.printError("\(dll): mode must be one of n,b | b,n | n | b")
            throw SevoExit.badInvocation
        }
        return (dll, mode)
    }

    /// A game's own translation layer. `auto` is the bottle's business — it
    /// consults CrossOver's per-game database — so a game names a layer or
    /// inherits.
    static func renderer(_ value: String) throws -> Renderer? {
        if value == "inherit" { return nil }
        guard let renderer = Renderer(rawValue: value), renderer != .auto else {
            Sevo.printError("renderer must be \(Renderer.gameRungs)")
            throw SevoExit.badInvocation
        }
        return renderer
    }

    static func filter(_ value: String) throws -> FinalFilter? {
        if value == "inherit" { return nil }
        guard let filter = FinalFilter(rawValue: value) else {
            Sevo.printError("filter must be nearest, bilinear, lanczos or inherit")
            throw SevoExit.badInvocation
        }
        return filter
    }

    /// A fixed choice, or the name of a package that is installed or in the
    /// catalog. A catalog package that is not installed is accepted and
    /// said so: the driver falls back to lanczos until it lands.
    static func upscaler(_ value: String) async throws -> String? {
        if value == "inherit" { return nil }
        if UpscalerChoice(rawValue: value) != nil { return value }
        let manifest = try? await EngineManifest.fetch()
        let catalog = ShaderPackages.catalog(manifest: manifest)
        switch ShaderPackages.choice(for: value, installed: ShaderPackages.installed(), catalog: catalog) {
        case .fixed, .installed:
            return value
        case let .downloadable(entry):
            Sevo.printError("\(entry.title) is in the catalog and not installed: the driver falls back to "
                + "lanczos until `sevo shaders install \(value)`")
            return value
        case nil:
            Sevo.printError("upscaler must be off, lanczos, metalfx, the name of an installed or "
                + "downloadable shader package (sevo shaders list), or inherit; with '\(value)' the "
                + "driver would fall back to lanczos and log one error line")
            throw SevoExit.badInvocation
        }
    }
}

/// The shader packages the presenter's upscaler can run. The CLI face of
/// Settings › Graphics › Shader packages.
struct ShadersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shaders",
        abstract: "Shader packages for the upscaler: what is installed, what can be fetched.",
        discussion: """
        list             installed packages, then the ones that can be fetched
        install <name>   fetch a package from the catalog, or copy the app's bundled one
        remove <name>    move a package to the Trash; a setting naming it is left as it is
        A package is chosen with sevo bottle config upscaler <name>, or per game with \
        sevo app config <appid> upscaler <name>.
        """,
    )

    @Argument(help: "list | install | remove") var verb: String = "list"
    @Argument(help: "The package's name, as list prints it.") var name: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list": try await list()
        case "install": try await install()
        case "remove": try remove()
        default:
            Sevo.printError("shaders \(verb): unknown verb (list | install | remove)")
            throw SevoExit.badInvocation
        }
    }

    private func list() async throws {
        ShaderPackages.ensureBundled()
        let installed = ShaderPackages.installed()
        let manifest = try? await EngineManifest.fetch()
        let catalog = ShaderPackages.catalog(manifest: manifest)
        let have = Set(installed.map(\.name))
        let available = catalog.filter { !have.contains($0.name) }
        if asJSON {
            print(Sevo.json([
                "installed": installed.map { package -> [String: Any] in
                    [
                        "name": package.name, "title": package.title, "version": package.manifest.version,
                        "license": package.manifest.license, "content": package.manifest.content,
                        "source": package.manifest.source?.absoluteString ?? NSNull(),
                        "path": package.root.path,
                    ]
                },
                "available": available.map { entry -> [String: Any] in
                    var row: [String: Any] = [
                        "name": entry.name, "title": entry.title, "version": entry.version,
                        "license": entry.license, "content": entry.content,
                        "source": entry.source?.absoluteString ?? NSNull(),
                        "size": entry.size ?? NSNull(),
                    ]
                    if case let .download(url, _, _) = entry.origin { row["url"] = url.absoluteString }
                    return row
                },
            ], pretty: true))
            return
        }
        print("installed")
        if installed.isEmpty { print("  none") }
        for package in installed {
            print("  \(package.name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(package.title) \(package.manifest.version) · \(package.manifest.license) — \(package.manifest.content)")
        }
        print("available")
        if available.isEmpty { print("  nothing further") }
        for entry in available {
            let size = entry.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            print("  \(entry.name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(entry.title) \(entry.version) · \(entry.license)\(size) — \(entry.content)")
        }
    }

    private func install() async throws {
        guard let name else {
            Sevo.printError("shaders install: name a package (sevo shaders list)")
            throw SevoExit.badInvocation
        }
        let manifest = try? await EngineManifest.fetch()
        guard let entry = ShaderPackages.catalog(manifest: manifest).first(where: { $0.name == name }) else {
            Sevo.printError("no shader package named \(name) in the catalog — sevo shaders list")
            throw SevoExit.badInvocation
        }
        do {
            // One line per whole percent, so a 60-second download does not
            // scroll a thousand of them.
            let lastPercent = Mutex(-1)
            let package = try await ShaderPackages.install(entry) { fraction in
                let percent = fraction.map { Int($0 * 100) } ?? -1
                let changed = lastPercent.withLock { last -> Bool in
                    guard last != percent else { return false }
                    last = percent
                    return true
                }
                guard changed else { return }
                let suffix = percent >= 0 ? " \(percent)%" : ""
                FileHandle.standardError.write(Data("downloading \(entry.title)\(suffix)\n".utf8))
            }
            print("\(package.title) \(package.manifest.version) installed at \(package.root.path)")
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
    }

    private func remove() throws {
        guard let name, let package = ShaderPackages.installed().first(where: { $0.name == name }) else {
            Sevo.printError("shaders remove: name an installed package (sevo shaders list)")
            throw SevoExit.badInvocation
        }
        try ShaderPackages.remove(package)
        print("\(package.title) moved to the Trash")
    }
}

struct BottleCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "bottle",
        abstract: "Bottles, whether Steam is installed in each, and their settings.",
        discussion: "windows takes \(WindowTreatment.help).",
    )

    @Argument(help: "list | config | deps [install <id>]") var verb: String = "list"
    @Argument(help: "Config key: renderer | msync | windows | upscaler | filter | mouse | retina | emulate-modeset | \(ConfigSwitches.names) | wine-debug. Omit to print every key.")
    var key: String?
    @Argument(help: "New value; for windows: \(WindowTreatment.rungs); for wine-debug: on to add exception traces and every library load, off for the errors the log always keeps, or Wine channels. Omit to read the key.")
    var value: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "config":
            try await config()
        case "deps":
            try await dependencies()
        default:
            Sevo.printError("bottle \(verb): unknown verb (list | config | deps)")
            throw SevoExit.badInvocation
        }
    }

    /// The fonts and runtimes Settings › Engine lists for the bottle: what is
    /// installed, and `deps install <id>` for one that is missing.
    private func dependencies() async throws {
        guard key == "install" else {
            let rows = BottleDependencies.catalog.map { dependency in
                (dependency, BottleDependencies.isInstalled(dependency))
            }
            if asJSON {
                print(Sevo.json(rows.map { dependency, installed in
                    [
                        "id": dependency.id,
                        "name": dependency.name,
                        "required": dependency.required,
                        "installed": installed,
                        "download": dependency.download,
                    ]
                }))
                return
            }
            for (dependency, installed) in rows {
                let state = installed ? "installed" : "missing, \(dependency.download)"
                let need = dependency.required ? "required" : "optional"
                print("\(installed ? "✔" : "✖") \(dependency.id)  \(dependency.name) (\(need), \(state))")
            }
            return
        }
        guard let id = value, BottleDependencies.catalog.contains(where: { $0.id == id }) else {
            let ids = BottleDependencies.catalog.map(\.id).joined(separator: " | ")
            Sevo.printError("bottle deps install: name one of \(ids)")
            throw SevoExit.badInvocation
        }
        let failure = await BottleDependencies.install(id) { phase in
            FileHandle.standardError.write(Data("\(phase)\n".utf8))
        }
        if let failure {
            Sevo.printError("bottle deps install \(id): \(failure)")
            throw SevoExit.failed
        }
        print("\(id) installed in bottle '\(SteamBottle.name)'")
    }

    /// Reads or writes the graphics knobs the app's Settings › Graphics pane
    /// drives, against the same store (`Sevoflurane/Support/BottleGraphics.swift`).
    private func config() async throws {
        var selection = current()
        // Debug mode folds its own channels into what a game carries, so the
        // effective set the operator sees has to account for its file.
        let debugMode = DebugMode.isWritten(prefix: SteamBottle.root)
        guard let key else {
            if asJSON {
                print(Sevo.json([
                    "renderer": selection.renderer.rawValue,
                    "msync": selection.msync,
                    "windows": GameConfig.windows(bottle: SteamBottle.name).value.rawValue,
                    "upscaler": GameConfig.upscaler(bottle: SteamBottle.name).value,
                    "filter": GameConfig.filter(bottle: SteamBottle.name).value.rawValue,
                    "mouse": GameConfig.mouse(bottle: SteamBottle.name).value.rawValue,
                    "retina": GameConfig.retina(bottle: SteamBottle.name).value,
                    "emulate-modeset": GameConfig.emulateModeset(bottle: SteamBottle.name).value,
                    "switches": Dictionary(uniqueKeysWithValues: ConfigSwitches.all.map {
                        ($0.key, ConfigSwitches.resolved(
                            $0.key, bottle: SteamBottle.name, game: nil,
                        )?.value ?? false)
                    }),
                    "wine-debug": debugMode || WineLog.isDiagnosing,
                    "wine-debug-channels": WineLog.channels,
                    "wine-debug-effective": WineLog.effectiveChannels(debugMode: debugMode),
                    "debug-mode": debugMode,
                ], pretty: true))
            } else {
                print("renderer \(selection.renderer.rawValue)")
                print("msync \(selection.msync)")
                print("windows \(Self.windowsSummary)")
                print("upscaler \(Self.upscalerSummary)")
                print("filter \(Self.filterSummary)")
                print("mouse \(Self.mouseSummary)")
                print("retina \(Self.retinaSummary)")
                print("emulate-modeset \(Self.modesetSummary)")
                for entry in ConfigSwitches.all {
                    print("\(entry.key) \(Self.switchSummary(entry.key))")
                }
                print("wine-debug \(WineLog.summary(debugMode: debugMode))")
            }
            return
        }
        guard let value else {
            switch key {
            case "renderer": print(selection.renderer.rawValue)
            case "msync": print(selection.msync)
            case _ where ConfigSwitches.path(for: key) != nil:
                print(Self.switchSummary(key))
            case "retina": print(Self.retinaSummary)
            case "emulate-modeset": print(Self.modesetSummary)
            case "windows": print(Self.windowsSummary)
            case "upscaler": print(Self.upscalerSummary)
            case "filter": print(Self.filterSummary)
            case "mouse": print(Self.mouseSummary)
            case "wine-debug": print(WineLog.summary(debugMode: debugMode))
            default:
                Sevo.printError("unknown key '\(key)' \(Self.keys)")
                throw SevoExit.badInvocation
            }
            return
        }
        if key == "windows" {
            // The built-in engine's window treatment at the bottle level;
            // `WindowTreatment.help` carries the rungs, and a game overrides
            // the bottle through `sevo app config`.
            let treatment = try ConfigKeyParsing.windows(value)
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.windows = treatment }
            print("windows \(Self.windowsSummary) — \(Self.gameReach)")
            return
        }
        if key == "upscaler" {
            // The presenter's upscaler at the bottle level: `off`, `lanczos`,
            // `metalfx`, a shader package's name, or `inherit`.
            let upscaler = try await ConfigKeyParsing.upscaler(value)
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.upscaler = upscaler }
            print("upscaler \(Self.upscalerSummary) — \(Self.gameReach)")
            return
        }
        if key == "filter" {
            // How the upscaler's last pass reaches the window: `nearest`,
            // `bilinear`, `lanczos`, or `inherit`.
            let filter = try ConfigKeyParsing.filter(value)
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.filter = filter }
            print("filter \(Self.filterSummary) — \(Self.gameReach)")
            return
        }
        if let path = ConfigSwitches.path(for: key) {
            let flag = try ConfigKeyParsing.flag(value, key: key)
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) {
                $0[keyPath: path] = flag
            }
            print("\(key) \(Self.switchSummary(key))"
                + (ConfigSwitches.caveat(key).map { " — \($0)" } ?? " — \(Self.gameReach)"))
            return
        }
        if key == "retina" {
            // The prefix's own HiDPI switch, written to the bottle's
            // `Mac Driver\\RetinaMode`; one answer for every process in it.
            let retina = try ConfigKeyParsing.flag(value, key: "retina")
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.retina = retina }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("retina \(Self.retinaSummary) — \(Self.gameReach)")
            return
        }
        if key == "emulate-modeset" {
            // Whether a game that switches the display mode has the switch
            // faked and its picture put in a window it can be resized in.
            let modeset = try ConfigKeyParsing.flag(value, key: "emulate-modeset")
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.emulateModeset = modeset }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("emulate-modeset \(Self.modesetSummary) — \(Self.gameReach)")
            return
        }
        if key == "mouse" {
            // What a game holding the cursor for mouse-look is given as
            // movement: `system` for the pointer curve everything else on the
            // Mac gets, `linear` for the mouse's own displacement, or
            // `inherit` for the global default.
            let curve = try ConfigKeyParsing.mouse(value)
            GameConfig.update(bottle: SteamBottle.name, prefix: SteamBottle.root) { $0.mouse = curve }
            print("mouse \(Self.mouseSummary) — \(Self.gameReach)")
            return
        }
        if key == "wine-debug" {
            // `on` adds every library load to the errors and exceptions the
            // log always keeps, `off` returns to those alone, anything else
            // is Wine's own channel syntax, e.g. `+seh,+loaddll`. Read by the
            // next client start, and inherited by every game it launches.
            switch value {
            case "on", "off": WineLog.setDiagnosing(value == "on")
            default: WineLog.setChannels(value)
            }
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("wine-debug \(WineLog.summary(debugMode: debugMode)) — \(Self.gameReach); in the "
                + "client from its next boot: sevo client restart; trail at \(WineLog.fileURL.path)")
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
            Sevo.printError("unknown key '\(key)' \(Self.keys)")
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

    private static let keys = "(renderer | msync | windows | upscaler | filter | mouse | "
        + "retina | emulate-modeset | \(ConfigSwitches.names) | wine-debug)"

    /// One switch's resolved value and where it comes from.
    static func switchSummary(_ key: String) -> String {
        guard let resolved = ConfigSwitches.resolved(key, bottle: SteamBottle.name, game: nil)
        else { return "unknown" }
        return "\(resolved.value) (\(resolved.source))"
    }

    /// Whether the prefix draws at the display's full resolution, and where
    /// that comes from.
    static var retinaSummary: String {
        let resolved = GameConfig.retina(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// Whether a display-mode switch is faked, and where that comes from.
    static var modesetSummary: String {
        let resolved = GameConfig.emulateModeset(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// The bottle's window treatment, where it comes from, and what it
    /// covers — the rung a reader cannot compare against its neighbors
    /// without being told what those are.
    static var windowsSummary: String {
        let resolved = GameConfig.windows(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source)) — \(resolved.value.summary)"
    }

    /// The bottle's upscaler and where it comes from.
    static var upscalerSummary: String {
        let resolved = GameConfig.upscaler(bottle: SteamBottle.name)
        return "\(resolved.value) (\(resolved.source))"
    }

    /// The bottle's final filter and where it comes from.
    static var filterSummary: String {
        let resolved = GameConfig.filter(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source))"
    }

    /// The bottle's mouse curve and where it comes from.
    static var mouseSummary: String {
        let resolved = GameConfig.mouse(bottle: SteamBottle.name)
        return "\(resolved.value.rawValue) (\(resolved.source))"
    }

    /// When a bottle-level value reaches games: at their next launch on an
    /// engine that reads the env files, after a client restart otherwise.
    static var gameReach: String {
        Engine.active.supportsEnvFiles
            ? "in games from their next launch"
            : "in games started after the client's next boot: sevo client restart"
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
                print("force-quit (\(scopeName)) \(routed ? "via app" : "direct"):")
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
            guard let reply = await AppControl.appLinkPost(path) else {
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

// MARK: - app / downloads

struct AppCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "app",
        abstract: "Library and per-app actions via the client's own API.",
        subcommands: [
            List.self, Info.self, Compat.self, Config.self, RepairDLL.self, Detect.self,
            Launch.self, Terminate.self, Install.self, Uninstall.self, Verify.self,
        ],
    )

    /// The same record the library page's strip draws, from the same cache:
    /// AreWeAntiCheatYet, AppleGamingWiki, ProtonDB, and Steam's Deck
    /// category when the client is up to say it.
    struct Compat: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "compat",
            abstract: "What the community databases say about a game on a Mac.",
        )
        @Argument var appid: Int
        @Option(help: "The game's title, for the wiki lookup. Read from the client when omitted.")
        var name: String?
        @Flag(help: "Ask every source again instead of reading the week-old cache.")
        var refresh = false
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            var title = name ?? ""
            var deck: Int?
            // The client, when it is up, knows the title and Valve's own
            // category; without it the wiki lookup needs `--name`.
            if let raw = try? await SteamOps.appInfo(appid),
               let info = try? JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any] {
                if title.isEmpty { title = info["name"] as? String ?? "" }
                deck = info["deck_compat_category"] as? Int
            }
            let record = await GameCompatService.shared.record(
                appID: appid, name: title, deckCategory: deck, ignoringCache: refresh,
            )
            if asJSON {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let json = try encoder.encode(record)
                print(String(decoding: json, as: UTF8.self))
                return
            }
            print("\(record.name.isEmpty ? String(appid) : record.name) (\(appid))")
            print("  Mac:        \(record.mac.label) — \(record.mac.reason)")
            print("  Anti-cheat: \(record.antiCheatBadge.label) — \(record.antiCheatBadge.reason)")
            if let wiki = record.wiki {
                let columns: [(String, String?)] = [
                    ("native", wiki.native), ("rosetta 2", wiki.rosetta2), ("crossover", wiki.crossover),
                    ("wine", wiki.wine), ("parallels", wiki.parallels),
                ]
                let tiers: [String] = columns.compactMap { name, tier in tier.map { "\(name) \($0)" } }
                print("  AppleGamingWiki: \(tiers.joined(separator: " · ")) — \(wiki.pageURL)")
            }
            if let proton = record.proton {
                print("  ProtonDB:   \(proton.tier) (\(proton.total) reports, \(proton.confidence)) — \(proton.sourceURL)")
            }
            if let deck = record.deckCategory {
                let words = [0: "unknown", 1: "unsupported", 2: "playable", 3: "verified"]
                print("  Steam Deck: \(words[deck] ?? String(deck))")
            }
        }
    }

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

    /// One game's settings: what it resolves to and from which level, and
    /// the game's own values. A value set here is written to the engine's
    /// per-program env file for every exe
    /// the game is known to run under.
    struct Config: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "config",
            abstract: "A game's own settings, over the bottle's and the global defaults.",
            discussion: """
            Keys: renderer (\(Renderer.gameRungs) — the translation layer \
            this game renders through, over the bottle's), emulate-modeset \
            (on | off | inherit — fakes a display-mode switch and shows the \
            result in a window), dll <name>=<mode> (n,b | b,n | n | b | \
            empty for disabled; <name>= drops one, inherit drops the \
            table), the switches \(ConfigSwitches.names) (on | off | \
            inherit), recommended to print what the fix table knows about \
            this game, windows \
            (\(WindowTreatment.help)), upscaler (off | \
            lanczos | metalfx | a shader package's name | inherit — sevo \
            shaders list names the packages), filter (nearest | bilinear | \
            lanczos | inherit — how the upscaler's last pass reaches the \
            window), mouse (system | linear | inherit — linear gives a game \
            holding the cursor for mouse-look the mouse's own displacement, \
            unshaped by the pointer acceleration curve), runner (wine | \
            nwjs — nwjs runs an NW.js game in native macOS NW.js and \
            downloads the runtime the first time), detect to look at the \
            game's files again, exe <name> to name an executable the game \
            runs under before its first launch has recorded one. Omit the \
            key to print every setting with the level it comes from.
            """,
        )
        @Argument var appid: Int
        @Argument(help: "renderer | windows | upscaler | filter | mouse | emulate-modeset | dll | \(ConfigSwitches.names) | runner | recommended | detect | exe. Omit to print every setting.")
        var key: String?
        @Argument(help: "New value; for windows: \(WindowTreatment.rungs). Omit to read the key.")
        var value: String?
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            let bottle = SteamBottle.name
            guard let key else {
                report(bottle: bottle)
                return
            }
            let values = GameConfig.game(appid)
            switch key {
            case "renderer":
                guard let value else {
                    let resolved = GameConfig.renderer(game: appid)
                    print("\(resolved.value.rawValue) (\(resolved.source)) — \(Self.rendererReach(appid))")
                    return
                }
                let renderer = try ConfigKeyParsing.renderer(value)
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.renderer = renderer }
            case _ where ConfigSwitches.path(for: key) != nil:
                guard let value else {
                    let resolved = ConfigSwitches.resolved(key, bottle: bottle, game: appid)
                    print("\(resolved?.value ?? false) (\(resolved?.source.description ?? "?"))")
                    return
                }
                let flag = try ConfigKeyParsing.flag(value, key: key)
                let path = ConfigSwitches.path(for: key)!
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) {
                    $0[keyPath: path] = flag
                }
            case "emulate-modeset":
                guard let value else {
                    let resolved = GameConfig.emulateModeset(bottle: bottle, game: appid)
                    print("\(resolved.value) (\(resolved.source))")
                    return
                }
                let modeset = try ConfigKeyParsing.flag(value, key: "emulate-modeset")
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.emulateModeset = modeset }
                await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            case "recommended":
                // Read-only on purpose: a recommendation is something to judge,
                // so it is printed and the user writes the key they agree with.
                print(Self.recommendedLines(appid, exes: values.exes ?? []))
                return
            case "dll":
                guard let value else {
                    print(Self.overrideLines(values))
                    return
                }
                try setDLLOverride(value, bottle: bottle)
                await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            case "windows":
                guard let value else {
                    let resolved = GameConfig.windows(bottle: bottle, game: appid)
                    print("\(resolved.value.rawValue) (\(resolved.source)) — \(resolved.value.summary)")
                    return
                }
                let treatment = try ConfigKeyParsing.windows(value)
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.windows = treatment }
            case "upscaler":
                guard let value else {
                    let resolved = GameConfig.upscaler(bottle: bottle, game: appid)
                    print("\(resolved.value) (\(resolved.source))")
                    return
                }
                let upscaler = try await ConfigKeyParsing.upscaler(value)
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.upscaler = upscaler }
            case "filter":
                guard let value else {
                    let resolved = GameConfig.filter(bottle: bottle, game: appid)
                    print("\(resolved.value.rawValue) (\(resolved.source))")
                    return
                }
                let filter = try ConfigKeyParsing.filter(value)
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.filter = filter }
            case "mouse":
                guard let value else {
                    let resolved = GameConfig.mouse(bottle: bottle, game: appid)
                    print("\(resolved.value.rawValue) (\(resolved.source))")
                    return
                }
                let curve = try ConfigKeyParsing.mouse(value)
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { $0.mouse = curve }
            case "tuning":
                guard let value else {
                    let resolved = GameConfig.tuning(bottle: bottle, game: appid)
                    let parameters = GameConfig.tuningParameters(bottle: bottle, game: appid)
                    print("\(resolved.value.rawValue) \(parameters.argument) (\(resolved.source))")
                    return
                }
                // `custom:<wait>,<adaptive 0|1>,<object>` names the preset and
                // its parameters in one value.
                let custom = value.hasPrefix("custom:")
                    ? TuningParameters(argument: String(value.dropFirst("custom:".count))) : nil
                let tuning = custom != nil ? PerformanceTuning.custom : PerformanceTuning(rawValue: value)
                guard tuning != nil && (tuning != .custom || custom != nil) || value == "inherit" else {
                    throw ValidationError(
                        "tuning is standard, experimental, custom:<wait spin>,<adaptive 0|1>,<object spin> "
                            + "(spins 0 to 1000000, 5200 is two microseconds) or inherit",
                    )
                }
                GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) {
                    $0.tuning = tuning
                    $0.tuningParameters = custom
                }
            case "runner":
                guard let value else {
                    print(values.runner ?? GameRunner.wine)
                    return
                }
                try await setRunner(value)
                ConfigMaterializer.materialize(bottle: bottle, prefix: SteamBottle.root)
            case "detect":
                try Detect.report(appid: appid, asJSON: asJSON)
                return
            case "exe":
                guard let value else {
                    print((values.exes ?? []).joined(separator: "\n"))
                    return
                }
                GameConfig.noteExecutable(value, forApp: appid)
                ConfigMaterializer.materialize(bottle: bottle, prefix: SteamBottle.root)
            default:
                Sevo.printError("unknown key '\(key)' (renderer | windows | upscaler | filter | "
                    + "mouse | emulate-modeset | dll | \(ConfigSwitches.names) | runner | "
                    + "recommended | detect | exe)")
                throw SevoExit.badInvocation
            }
            report(bottle: bottle)
        }

        /// Writes, changes or drops one DLL's load order for this game. An
        /// empty table is removed rather than left as a key that says nothing.
        private func setDLLOverride(_ value: String, bottle: String) throws {
            let parsed = try ConfigKeyParsing.dllOverride(value)
            GameConfig.update(game: appid, bottle: bottle, prefix: SteamBottle.root) { values in
                guard let parsed else {
                    values.dllOverrides = nil
                    return
                }
                var table = values.dllOverrides ?? [:]
                table[parsed.dll] = parsed.mode
                values.dllOverrides = table.isEmpty ? nil : table
            }
        }

        /// What the fix table says about this game: the keys it names, the
        /// values it names them with, and the measurement behind each.
        private static func recommendedLines(_ appid: Int, exes: [String]) -> String {
            let recommendation = KnownFixes.recommended(for: appid, exes: exes)
            guard !recommendation.isEmpty else {
                return "nothing — no entry in the fix table names this game"
            }
            return recommendation.fixes.map { fix in
                let keys = ConfigMaterializer.gameLines(appid, fix.values)
                    .dropFirst()
                    .joined(separator: " ")
                return "\(fix.title): \(keys.isEmpty ? "see below" : keys)\n  \(fix.reason)"
            }.joined(separator: "\n")
        }

        /// This game's own load orders, one per line.
        private static func overrideLines(_ values: ConfigValues) -> String {
            let table = values.dllOverrides ?? [:]
            guard !table.isEmpty else { return "none — the bottle's own overrides apply" }
            return table.sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value.isEmpty ? "disabled" : $0.value)" }
                .joined(separator: "\n")
        }

        /// What a renderer set for this game costs to reach it: its own env
        /// file at the next launch, or the client restart the menu bar offers.
        private static func rendererReach(_ appid: Int) -> String {
            SettingReach.renderer(GameConfig.game(appid).renderer).detail
        }

        /// Switches the game between the bottle's engine and native NW.js,
        /// fetching the runtime that matches the game's own build the first
        /// time it is asked for.
        private func setRunner(_ value: String) async throws {
            var values = GameConfig.game(appid)
            switch value {
            case GameRunner.wine:
                values.runner = nil
                values.nwjsRuntime = nil
            case GameRunner.nwjs:
                guard let info = values.nwjs ?? NWJSGames.record(appID: appid) else {
                    Sevo.printError("app \(appid): not an NW.js game")
                    throw SevoExit.badInvocation
                }
                guard !info.version.isEmpty else {
                    Sevo.printError("app \(appid): could not read the NW.js version out of "
                        + "\(info.dir)/nw.dll")
                    throw SevoExit.failed
                }
                let wanted = await NWJSRuntime.release(forGameVersion: info.version)
                do {
                    _ = try await NWJSRuntime.ensure(version: wanted) { label, fraction in
                        let percent = fraction.map { " \(Int($0 * 100))%" } ?? ""
                        FileHandle.standardError.write(Data("\(label)\(percent)\n".utf8))
                    }
                } catch {
                    Sevo.printError("\(error)")
                    throw SevoExit.failed
                }
                if let caution = info.caution {
                    Sevo.printError("app \(appid): \(caution)")
                }
                // Detection may have rewritten the file since it was read.
                values = GameConfig.game(appid)
                values.runner = GameRunner.nwjs
                values.nwjs = info
                values.nwjsRuntime = wanted
            default:
                Sevo.printError("runner must be \(GameRunner.all.joined(separator: " or "))")
                throw SevoExit.badInvocation
            }
            GameConfig.setGame(appid, values)
        }

        private func report(bottle: String) {
            let renderer = GameConfig.renderer(game: appid)
            let modeset = GameConfig.emulateModeset(bottle: bottle, game: appid)
            let windows = GameConfig.windows(bottle: bottle, game: appid)
            let upscaler = GameConfig.upscaler(bottle: bottle, game: appid)
            let filter = GameConfig.filter(bottle: bottle, game: appid)
            let mouse = GameConfig.mouse(bottle: bottle, game: appid)
            let values = GameConfig.game(appid)
            let exes = values.exes ?? []
            let runner = values.runner ?? GameRunner.wine
            if asJSON {
                var payload: [String: Any] = [
                    "appid": appid,
                    "renderer": [
                        "value": renderer.value.rawValue, "source": renderer.source.description,
                        "reach": Self.rendererReach(appid),
                    ],
                    "windows": [
                        "value": windows.value.rawValue, "source": windows.source.description,
                    ],
                    "upscaler": [
                        "value": upscaler.value, "source": upscaler.source.description,
                    ],
                    "filter": [
                        "value": filter.value.rawValue, "source": filter.source.description,
                    ],
                    "mouse": [
                        "value": mouse.value.rawValue, "source": mouse.source.description,
                    ],
                    "emulate-modeset": [
                        "value": modeset.value, "source": modeset.source.description,
                    ],
                    "dll-overrides": values.dllOverrides ?? [:],
                    "switches": Dictionary(uniqueKeysWithValues: ConfigSwitches.all.map {
                        ($0.key, ConfigSwitches.resolved(
                            $0.key, bottle: bottle, game: appid,
                        )?.value ?? false)
                    }),
                    "runner": runner,
                    "exes": exes,
                ]
                payload["nwjs"] = values.nwjs.map { info -> Any in
                    [
                        "version": info.version, "dir": info.dir,
                        "flavor": info.flavor ?? NSNull(),
                        "greenworks": info.greenworks,
                        "greenworks_cloud": info.greenworksCloud ?? NSNull(),
                        "packageName": info.packageName,
                    ] as [String: Any]
                } ?? NSNull()
                print(Sevo.json(payload, pretty: true))
                return
            }
            print("renderer \(renderer.value.rawValue) (\(renderer.source)) — \(Self.rendererReach(appid))")
            print("windows \(windows.value.rawValue) (\(windows.source)) — \(windows.value.summary)")
            print("upscaler \(upscaler.value) (\(upscaler.source))")
            print("filter \(filter.value.rawValue) (\(filter.source))")
            print("mouse \(mouse.value.rawValue) (\(mouse.source))")
            print("emulate-modeset \(modeset.value) (\(modeset.source))")
            print("dll \(Self.overrideLines(values).replacingOccurrences(of: "\n", with: " "))")
            for entry in ConfigSwitches.all {
                let resolved = ConfigSwitches.resolved(entry.key, bottle: bottle, game: appid)
                print("\(entry.key) \(resolved?.value ?? false) (\(resolved?.source.description ?? "?"))"
                    + (ConfigSwitches.caveat(entry.key).map { " — \($0)" } ?? ""))
            }
            print("runner \(runner)")
            if let info = values.nwjs {
                print(info.summary)
                if let runtime = values.nwjsRuntime {
                    print("runtime nwjs \(runtime) \(NWJSRuntime.nativeFlavor)"
                        + (runtime == info.version ? "" : " — the game's own \(info.version) has "
                            + "no build this Mac runs without translation"))
                }
            }
            print("exes \(exes.isEmpty ? "none yet — recorded at the first launch" : exes.joined(separator: " "))")
            var reach = Engine.active.supportsEnvFiles
                ? "settings reach the game at its next launch"
                : "needs an engine that reads the env files (Dormison r2 or later)"
            if exes.isEmpty {
                reach += "; its exe is not known yet, so a value lands one launch late"
            }
            print("— \(reach)")
        }
    }

    /// Puts a DLL a run said was missing back: installs the package that
    /// carries it, then gives this game the native copy.
    struct RepairDLL: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "repair-dll",
            abstract: "Install what carries a missing DLL and take it for one game.",
            discussion: """
            For a launch that ended in 0xc0000135 or "X.dll was not found". \
            The package is installed in the bottle once; the load order is \
            this game's alone and reaches it at its next launch.
            """,
        )
        @Argument var appid: Int
        @Argument(help: "The DLL the game could not find, with or without .dll.")
        var dll: String
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            guard let repair = KnownFixes.dllRepair(for: dll) else {
                Sevo.printError("no package in the dependency catalog carries \(dll) "
                    + "(sevo doctor lists what a bottle has)")
                throw SevoExit.badInvocation
            }
            if BottleDependencies.catalog.first(where: { $0.id == repair.dependency })
                .map(BottleDependencies.isInstalled) == true {
                print("\(repair.packageName) is already installed")
            } else {
                print("installing \(repair.packageName)…")
                if let failure = await BottleDependencies.install(repair.dependency, phase: {
                    FileHandle.standardError.write(Data("  \($0)\n".utf8))
                }) {
                    Sevo.printError("\(repair.packageName): \(failure)")
                    throw SevoExit.failed
                }
            }
            GameConfig.update(game: appid, bottle: SteamBottle.name, prefix: SteamBottle.root) {
                KnownFixes.apply(repair, to: &$0)
            }
            await ConfigRegistry.settle(bottle: SteamBottle.name, prefix: SteamBottle.root)
            if asJSON {
                print(Sevo.json([
                    "appid": appid, "dll": repair.dll, "mode": repair.mode,
                    "package": repair.dependency,
                ], pretty: true))
                return
            }
            print("\(repair.dll)=\(repair.mode) for app \(appid) — reaches it at its next launch")
        }
    }

    /// Looks at a game's files again and records what they are: the NW.js
    /// build it ships, if any. The app does this for the whole installed
    /// library at every client start, so this is for a game that has just
    /// been installed or updated.
    struct Detect: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "detect",
            abstract: "Read a game's files and record what runtime it is built on.",
        )
        @Argument var appid: Int
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            try Self.report(appid: appid, asJSON: asJSON)
        }

        static func report(appid: Int, asJSON: Bool) throws {
            guard SharedGames.installDirectory(appID: appid) != nil else {
                Sevo.printError("app \(appid) is not installed in \(SteamBottle.name)")
                throw SevoExit.failed
            }
            let found = NWJSGames.record(appID: appid)
            if asJSON {
                print(Sevo.json([
                    "appid": appid,
                    "nwjs": found.map { info -> Any in
                        [
                            "version": info.version, "dir": info.dir, "main": info.main,
                            "flavor": info.flavor ?? NSNull(), "greenworks": info.greenworks,
                            "greenworks_cloud": info.greenworksCloud ?? NSNull(),
                            "packageName": info.packageName,
                        ] as [String: Any]
                    } ?? NSNull(),
                ], pretty: true))
            } else if let found {
                print(found.summary)
                if let caution = found.caution { print("caution: \(caution)") }
                print("dir \(found.dir)")
                print("page \(found.main)")
                print("data \(found.packageName)")
                print("— sevo app config \(appid) runner nwjs runs it natively")
            } else {
                print("no native runtime detected — this game runs on the bottle's engine")
            }
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch",
            abstract: "Apps.RunGame, then report the game window that appears.",
        )
        @Argument var appid: Int
        @Option(name: .customLong("timeout"), help: "Seconds to wait for the window (default 180).")
        var timeout = 180
        @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let before = await WindowReport.currentWindow()
                await warnAboutRunningApps()
                let stuckInSync = await isStuckInCloudSync()
                try await SteamOps.launch(appid)
                narrate("launch requested for \(appid) — waiting for its window", asJSON: asJSON)
                let window = await WindowReport.awaitWindow(
                    forApp: appid, before: before, timeout: timeout,
                ) {
                    narrate($0, asJSON: asJSON)
                }
                if asJSON {
                    var payload: [String: Any] = [
                        "verdict": window != nil ? "confirmed" : stuckInSync ? "noEffect" : "unverifiable",
                        "intent": "app launch",
                        "appid": appid,
                    ]
                    payload["window"] = window.map { $0 as Any } ?? NSNull()
                    print(Sevo.json(payload, pretty: true))
                } else if let window {
                    print("app launch: confirmed — game window up")
                    for line in WindowReport.lines(window) {
                        print("  \(line)")
                    }
                } else if stuckInSync {
                    print("app launch: no effect — Steam kept \(appid) at Synchronizing and dropped the launch"
                        + " (sevo client restart)")
                } else {
                    print("app launch: unverifiable — no game window within \(timeout)s"
                        + " (is Sevoflurane running? poll: sevo status)")
                }
            }
        }

        /// A game force-ended during its Steam Cloud sync stays at Synchronizing, and the
        /// client accepts and drops every later launch of it. Restarting the client clears it.
        private func isStuckInCloudSync() async -> Bool {
            guard await (try? SteamOps.displayStatus(appid)) == SteamOps.DisplayStatus.synchronizing else {
                return false
            }
            narrate(
                "Steam shows \(appid) as Synchronizing before this launch — a sync that was cut off holds "
                    + "it there, and the client drops launches until it restarts (sevo client restart)",
                asJSON: asJSON,
            )
            return true
        }

        /// Steam refuses a second game while it believes one is running, and
        /// it believes that of any game whose entry outlived its process — so
        /// a non-empty list before the ask is the likeliest reason the launch
        /// that follows does nothing at all.
        private func warnAboutRunningApps() async {
            let running = await (try? SteamOps.runningApps()) ?? []
            guard !running.isEmpty else { return }
            let others = running.filter { $0 != appid }
            guard !others.isEmpty else {
                narrate("\(appid) is already listed as running", asJSON: asJSON)
                return
            }
            narrate(
                "Steam still lists \(others.map(String.init).joined(separator: ", ")) "
                    + "as running — this launch is a no-op until that clears "
                    + "(sevo app terminate <appid>)",
                asJSON: asJSON,
            )
        }
    }

    struct Terminate: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "terminate",
            abstract: "Apps.TerminateApp, then wait for the game to actually go.",
        )
        @Argument var appid: Int
        @Option(
            name: .customLong("timeout"),
            help: "Seconds to wait before signaling the game's processes (default 20).",
        )
        var timeout = 20
        @Flag(name: .customLong("json"), help: "Machine-readable verdict.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                try await SteamOps.terminate(appid)
                // A game on the native runner left the bottle at its first
                // instruction, so the client's terminate only drops its
                // record — the process itself is asked here.
                let native = GameConfig.game(appid).runsNatively
                    ? NWJSRunner.terminate(appID: appid) : []
                narrate(
                    "terminate requested for \(appid)"
                        + (native.isEmpty ? "" : " — and \(native.count) native "
                            + "process\(native.count == 1 ? "" : "es") asked to quit")
                        + " — waiting up to \(timeout)s for it to go",
                    asJSON: asJSON,
                )
                var sighting = await GameStop.waitUntilGone(appid: appid, seconds: timeout)
                var verdict = GameStop.Verdict.terminated
                if !sighting.isGone {
                    // The record and the processes are separate survivors: a
                    // stale entry is what makes every later RunGame a silent
                    // no-op, and only the client clears it, so what can be
                    // signaled here is the tree.
                    for pid in sighting.processes { kill(pid, SIGKILL) }
                    narrate(
                        "it did not go — SIGKILL'd \(sighting.processes.count) "
                            + "process\(sighting.processes.count == 1 ? "" : "es")",
                        asJSON: asJSON,
                    )
                    sighting = await GameStop.waitUntilGone(appid: appid, seconds: 5)
                    verdict = sighting.isGone ? .killed : .stillRunning
                }
                report(verdict, sighting)
            }
        }

        private func report(_ verdict: GameStop.Verdict, _ sighting: GameStop.Sighting) {
            guard !asJSON else {
                print(Sevo.json([
                    "verdict": verdict.rawValue,
                    "intent": "app terminate",
                    "appid": appid,
                    "steam_lists_it": sighting.steamListsIt,
                    "processes": sighting.processes.map(Int.init),
                ], pretty: true))
                return
            }
            print("app terminate: \(verdict.rawValue) — \(sighting.description)")
            if verdict == .stillRunning, sighting.steamListsIt, sighting.processes.isEmpty {
                print("  Steam's entry outlived the game: every later launch is a "
                    + "silent no-op until it clears. Restart the client: sevo client restart")
            }
        }
    }

    struct Install: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "install", abstract: "Queue an install with the default folder.",
        )
        @Argument var appid: Int
        @Flag(help: "Accept the game's license agreement when Steam shows one.")
        var acceptLicense = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await SteamOps.install(appid, acceptLicense: acceptLicense)
                switch outcome {
                case "ok": print("install queued for \(appid) — watch: sevo downloads status")
                case "ok license-accepted":
                    print("install queued for \(appid), its license agreement accepted — watch: sevo downloads status")
                case "no-wizard": print("Steam did not open an install for \(appid): the account holds no license for it. Add it to the library from its store page first.")
                case "license":
                    print("Steam is showing the license agreement for \(appid). Accept it in the Steam window, or run this again with --accept-license.")
                default: print("install of \(appid) stopped: \(outcome)")
                }
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
            commandName: "status", abstract: "What Steam is downloading now, in a line; --json for Steam's whole snapshot.",
        )

        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let snapshot = try await SteamOps.downloadsStatus()
                print(asJSON ? snapshot : Self.summary(of: snapshot))
            }
        }

        /// Steam's overview as a sentence: the app, the state, how far along
        /// and how fast. The snapshot itself carries two minutes of history.
        static func summary(of snapshot: String) -> String {
            guard let overview = (try? JSONSerialization.jsonObject(with: Data(snapshot.utf8))) as? [String: Any]
            else { return "no answer from Steam's download queue" }
            let paused = overview["paused"] as? Bool == true
            guard let appID = overview["update_appid"] as? Int, appID != 0 else {
                return paused ? "downloads paused, nothing queued" : "nothing downloading"
            }
            let state = (overview["update_state"] as? String ?? "").lowercased()
            let percent = overview["overall_percent_complete"] as? Int ?? 0
            let rate = overview["update_network_bytes_per_second"] as? Int64 ?? 0
            var line = "app \(appID): \(state.isEmpty ? "queued" : state), \(percent)%"
            if rate > 0 {
                line += " at \(ByteCountFormatter.string(fromByteCount: rate, countStyle: .file))/s"
            }
            if let seconds = overview["overall_estimated_time_remaining_sec"] as? Int, seconds > 0 {
                line += ", about \(seconds / 60 + 1) min left"
            }
            return paused ? line + " (paused)" : line
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
        The program is a Unix or Windows path. Flags before it are sevo's, \
        everything from it onward is the program's — so a program's own \
        flags need no -- separator. Wine's output goes to the terminal; set \
        its channels with sevo bottle config wine-debug.
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
        // Everything from the first token onward is captured for the program,
        // so the help flag is answered here rather than by the parser.
        guard first != "--help", first != "-h" else {
            throw CleanExit.helpRequest(self)
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

/// `sevo program`: the Windows programs added outside Steam — a visual novel
/// bought elsewhere, a tool, an installer.
///
/// Adding one writes a record beside the Steam games, so every per-game
/// setting, the launcher bundle and the Games pane reach it unchanged.
/// Starting one goes through the daemon, which is the bottle's one parent.
struct ProgramCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "program",
        abstract: "Windows programs you added outside Steam.",
        subcommands: [Add.self, List.self, Remove.self, Launch.self, Run.self],
    )

    struct Add: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "add",
            abstract: "Add a Windows program to Quick Launch.",
        )
        @Argument(help: "The .exe, as a macOS path.") var path: String
        @Option(name: .customLong("name"), help: "What to call it (default: its own name).")
        var name: String?
        @Option(name: .customLong("arg"), help: "An argument for the program; repeatable.")
        var arguments: [String] = []
        @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

        func run() async throws {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard FileManager.default.fileExists(atPath: url.path) else {
                Sevo.printError("no file at \(url.path)")
                throw SevoExit.badInvocation
            }
            guard PEResources.isExecutable(url) else {
                Sevo.printError("\(url.lastPathComponent) is not a Windows executable")
                throw SevoExit.badInvocation
            }
            let verdict = ProgramDetection.classify(url)
            let id = AdoptedPrograms.adopt(
                exe: url, name: name, kind: verdict.kind, arguments: arguments,
                bottle: SteamBottle.name,
            )
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            let entry = AdoptedPrograms.entry(id)
            if asJSON {
                print(Sevo.json([
                    "id": id, "name": entry?.name ?? url.lastPathComponent,
                    "kind": verdict.kind, "path": url.path,
                ], pretty: true))
            } else {
                print("added \(entry?.name ?? url.lastPathComponent) as \(id) (\(verdict.kind))")
                if !verdict.reasons.isEmpty {
                    print("  \(verdict.summary)")
                }
                print("  run it: sevo program launch \(id)")
            }
        }
    }

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "list", abstract: "Every added program.",
        )
        @Flag(name: .customLong("json"), help: "Machine-readable listing.") var asJSON = false

        func run() async throws {
            let programs = AdoptedPrograms.all()
            guard asJSON else {
                guard !programs.isEmpty else {
                    print("no added programs — sevo program add <path to .exe>")
                    return
                }
                for entry in programs {
                    print("\(entry.id)  \(entry.name)  [\(entry.kind)]  \(entry.program.path)")
                }
                return
            }
            print(Sevo.json(["programs": programs.map { entry in
                [
                    "id": entry.id, "name": entry.name, "kind": entry.kind,
                    "path": entry.program.path, "arguments": entry.program.arguments,
                    "bottle": entry.program.bottle, "exists": entry.program.exists,
                ] as [String: Any]
            }], pretty: true))
        }
    }

    struct Remove: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "remove",
            abstract: "Forget a program; an installer's files go to the Trash.",
        )
        @Argument(help: "The id from sevo program list.") var id: Int

        func run() async throws {
            guard let program = StorageInventory.addedPrograms().first(where: { $0.id == id })
            else {
                Sevo.printError("no added program with id \(id) — sevo program list")
                throw SevoExit.badInvocation
            }
            do {
                try StorageInventory.remove(program: program)
            } catch {
                Sevo.printError("could not remove \(program.name): \(error.localizedDescription)")
                throw SevoExit.failed
            }
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            print("removed \(program.name)"
                + (program.isInsideBottle ? " and moved its files to the Trash" : ""))
        }
    }

    struct Launch: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "launch", abstract: "Start an added program in the bottle.",
        )
        @Argument(help: "The id from sevo program list.") var id: Int
        @Option(name: .customLong("renderer"), help: "Run it on this renderer for once.")
        var renderer: String?
        @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.launchProgram(id: id, renderer: renderer)
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }

    struct Run: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "run",
            abstract: "Run a Windows program once, keeping no record of it.",
        )
        @Argument(help: "The .exe, as a macOS path.") var path: String
        @Argument(parsing: .captureForPassthrough, help: "Arguments for the program.")
        var arguments: [String] = []
        @Flag(name: .customLong("wait"), help: "Stay until it and its children exit.")
        var wait = false
        @Flag(name: .customLong("json"), help: "Machine-readable observation.") var asJSON = false

        func run() async throws {
            try await handlingFailures {
                let outcome = try await ClientOps.runProgram(
                    at: URL(fileURLWithPath: path).standardizedFileURL.path,
                    arguments: arguments, wait: wait,
                )
                await StatusReport.emit(outcome, asJSON: asJSON)
            }
        }
    }
}

/// `sevo runs`: what every game launch did, from the run records.
struct RunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "The last game launches: what each ran on, how long, and how it ended.",
        discussion: """
        One line per launch, oldest first, with the recognized failure beneath \
        the ones the app knows. Records live in ~/Library/Application \
        Support/Sevoflurane/Runs, one JSON Lines file per month.
        """,
    )

    @Option(name: .customLong("last"), help: "How many launches to print.") var last = 20
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let records = RunLog.recent(max(1, last))
        if asJSON {
            print(Sevo.json(records.map(Self.row), pretty: true))
            return
        }
        guard !records.isEmpty else {
            print("no runs recorded yet — launch a game and look again")
            return
        }
        for record in records {
            print("\(Self.moment(record.t))  \(record.summary)")
            guard let failure = KnownFailures.match(record) else { continue }
            print("    \(failure.summary)")
            if let fix = failure.fix { print("    fix: \(fix)") }
        }
    }

    /// The record as it sits on disk, plus what the app recognizes in it — a
    /// caller reading JSON wants the match without repeating the table.
    private static func row(_ record: RunRecord) -> [String: Any] {
        var row = (try? JSONEncoder().encode(record))
            .flatMap { Sevo.jsonObject(String(decoding: $0, as: UTF8.self)) } ?? [:]
        if let failure = KnownFailures.match(record) {
            var known: [String: Any] = ["id": failure.id, "summary": failure.summary]
            if let fix = failure.fix { known["fix"] = fix }
            row["known_failure"] = known
        }
        return row
    }

    /// The record's UTC stamp in this Mac's own time, which is what the event
    /// log beside it is written in.
    private static func moment(_ stamp: String) -> String {
        guard let date = runRecordStamp.date(from: stamp) else { return stamp }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm"
        local.locale = Locale(identifier: "en_US_POSIX")
        return local.string(from: date)
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

// MARK: - debug mode

/// `sevo debug` — the playtest switch, as a scripted playtest reaches it.
///
/// The mode is a session of the running app: it holds the state, it flushes
/// its own log line by line while it is on, and it turns everything off when
/// it quits. So `on` needs the app, and only `off` can act without it — to
/// clear the env file a killed session left in the bottle.
struct DebugCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "debug",
        abstract: "The playtest switch: verbose engine and app logging until the app quits.",
        subcommands: [On.self, Off.self, Status.self],
        defaultSubcommand: Status.self,
    )

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "on", abstract: "Turn debug mode on (needs the app running).",
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            guard let reply = await AppControl.post("/debug/on") else {
                Sevo.printError(
                    "the app is not running — debug mode is a session of it; open Sevoflurane first",
                )
                throw SevoExit.unreachable
            }
            DebugCommand.report(reply, asJSON: asJSON)
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "off", abstract: "Turn debug mode off.",
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            if let reply = await AppControl.post("/debug/off") {
                DebugCommand.report(reply, asJSON: asJSON)
                return
            }
            // No app, so no session — but a killed one can have left its file
            // in the bottle, where the next program to start would read it.
            let cleared = ConfigMaterializer.removeDebugEnv(prefix: SteamBottle.root)
            let note = cleared
                ? "the app is not running; deleted the env file a previous session left behind"
                : "the app is not running; there was nothing to turn off"
            print(asJSON ? Sevo.json(["on": false, "note": note], pretty: true) : "debug mode off — \(note)")
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "Whether debug mode is on, and where its file is.",
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            if let reply = await AppControl.get("/debug") {
                DebugCommand.report(reply, asJSON: asJSON)
                return
            }
            let url = DebugMode.envURL(prefix: SteamBottle.root)
            let stale = DebugMode.isWritten(prefix: SteamBottle.root)
            let note = stale
                ? "the app is not running, and \(url.path) is a killed session's — sevo debug off"
                : "the app is not running"
            print(asJSON ? Sevo.json(["on": false, "note": note], pretty: true) : "debug mode off — \(note)")
        }
    }

    /// The app's own answer, printed as JSON or as the line it describes.
    private static func report(_ reply: Data, asJSON: Bool) {
        guard !asJSON else {
            print(String(decoding: reply, as: UTF8.self))
            return
        }
        let object = (try? JSONSerialization.jsonObject(with: reply)) as? [String: Any]
        let on = object?["on"] as? Bool == true
        let note = object?["note"] as? String ?? ""
        print("debug mode \(on ? "on" : "off") — \(note)")
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

/// The NW.js runtime store. Games are pointed at a runtime by
/// `sevo app config <id> runner nwjs`, which fetches the release the game's
/// own build calls for; this is the store behind it, and the way to fill it
/// on a Mac that cannot reach `dl.nwjs.io`.
struct NWJSCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "nwjs",
        abstract: "The NW.js runtimes games run natively on.",
    )

    @Argument(help: "list | add") var verb: String = "list"
    @Argument(help: "For add: an unpacked nwjs-v<version>-<flavor> folder, or the nwjs.app in one.")
    var path: String?
    /// Not `--version`: the root command already owns that word, and a
    /// subcommand that takes it over makes `sevo nwjs --version` mean two
    /// things at once.
    @Option(
        name: .customLong("release"),
        help: "For add: the NW.js version, when the folder's name does not say.",
    ) var release: String?

    func run() async throws {
        switch verb {
        case "list":
            list()
        case "add":
            try await add()
        default:
            Sevo.printError("nwjs \(verb): unknown verb (list | add)")
            throw SevoExit.badInvocation
        }
    }

    private func list() {
        let installed = NWJSRuntime.installed()
        guard !installed.isEmpty else {
            print("no NW.js runtimes — one is fetched when a game is switched to the native runner")
            return
        }
        for version in installed {
            print("nwjs \(version)  \(NWJSRuntime.directory(version: version).path)")
        }
    }

    private func add() async throws {
        guard let path, !path.isEmpty else {
            Sevo.printError("nwjs add: name the folder to add")
            throw SevoExit.badInvocation
        }
        let folder = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        do {
            let installed = try await NWJSRuntime.install(fromFolder: folder, version: release)
            print("nwjs \(installed) installed")
        } catch {
            Sevo.printError("\(error)")
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
