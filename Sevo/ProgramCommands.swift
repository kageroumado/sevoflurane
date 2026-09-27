import ArgumentParser
import Foundation

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
        
        A program started here gets no run record, frame trace or collected \
        report: those open when the app sees a game launch start, as sevo \
        app launch and the library do. For a diagnostic run of a game, launch \
        it that way; sevo diag --help has the guide.
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
