import ArgumentParser
import Foundation

/// `sevo diag`: what a bug report needs, in one zip on the Desktop — and the
/// level the next game runs at.
struct DiagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag",
        abstract: "The zip a bug report needs, and how much the next run records.",
        discussion: """
        Making a run worth reading:
          1. Set the level before the launch: sevo diag on (level 1), or
             sevo diag on --level 2 for a bug that survives level 1. A level
             reaches each game at its next launch; Steam keeps running.
          2. Play at least 60 s past loading, in a scene you can return to.
             Loading and shader compilation are the first seconds of every
             trace; sevo perf compare --skip <s> leaves them out.
          3. To measure a setting, change that one setting between runs and
             run each side at least twice, in the same scene.
          4. Name what the record cannot tell apart: sevo perf label 1 "<name>".
          5. Compare: sevo perf compare --game <appid> (sevo perf --help).
          6. Right after the problem shows, write the zip: sevo diag save.
          7. sevo diag off when done. Level 2 turns itself off after one run.
        
        Levels:
          0  Always on. The run record, the frame trace, the event log,
             Wine's errors, and a collected report after a crash or a stall
             kill. Costs nothing measurable.
          1  Adds Wine's +seh exception channel, the DXMT, DXVK and D3DMetal
             logs, and a collected report after every run.
          2  Adds +loaddll,+module, the presentation, presenter and graphics
             logs, whole minidumps, the machine's state every 10 s in the
             event log, and the report compressed when the run closes.
        
        sevo diag status --help lists what each part records and where it
        lands; sevo diag save --help says what the zip holds and what is
        taken out of it. sevo debug on is the session switch that records
        everything until the app quits.
        """,
        subcommands: [Save.self, On.self, Off.self, Status.self],
        defaultSubcommand: Save.self,
    )

    /// `sevo diag` with no subcommand, which is what every script that
    /// predates the levels calls.
    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Write a zip of the logs, a doctor report and the engine's identity.",
            discussion: """
            Save it right after the problem: crash reports older than 48 h and
            run records from before this month stay out.
            
            The zip holds the event log and the Wine log (with their previous
            rotations), doctor.json, status.json, host.json (Mac model, chip,
            memory, macOS, app and engine versions, audio output), the active
            engine's engine-info.json, the bottle's env files and per-game
            files, the list of launcher bundles, Steam's own logs, this month's
            run records with the logs each game wrote for itself, and the macOS
            crash reports of the engine's processes. contents.txt lists it.
            
            Every file passes through redaction on the way in: a path under a
            home directory becomes ~, the bottle's Windows user becomes ~, this
            Mac's names become <host>, the account's name <user>, Steam ids
            <steamid>. Collected run reports also replace persona names with
            <persona>.
            """,
        )

        @Option(
            name: .customLong("output"),
            help: "A directory, or a .zip path. Default: the Desktop.",
        ) var output: String?
        @Flag(
            name: .customLong("steam-logs"),
            inversion: .prefixedNo,
            help: "Steam's own bootstrap, connection, webhelper, game-process and console logs from the bottle.",
        ) var steamLogs = true
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            Diagnostics.faceReport = { await DiagCommand.faceReport() }
            let destination = output.map {
                URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath)
            }
            let zip = try await Diagnostics.bundle(to: destination, steamLogs: steamLogs)
            print(asJSON ? Sevo.json(["path": zip.path]) : zip.path)
        }
    }

    struct On: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "on",
            abstract: "Record more of every run, from the next game launched.",
        )

        @Option(
            name: .customLong("level"),
            help: "1 for the diagnostics set, 2 for everything (2 turns itself off after one run).",
        ) var level = 1
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            guard let wanted = DiagnosticLevel(rawValue: level), wanted != .zero else {
                Sevo.printError("level must be 1 or 2; sevo diag off turns diagnostics off")
                throw SevoExit.failed
            }
            DiagCommand.report(DiagnosticLevel.set(wanted), asJSON: asJSON)
        }
    }

    struct Off: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "off", abstract: "Back to what every run records anyway.",
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            DiagCommand.report(DiagnosticLevel.set(.zero), asJSON: asJSON)
        }
    }

    struct Status: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "status", abstract: "The level in force, and what it costs.",
            discussion: """
            What records a run, and where it lands (~/Library/…):
              run record     one JSON line per launch: engine, renderer, tuning,
                             upscaler, first window, duration, exit, the last
                             exception, renderer notes, the frame-rate summary.
                             Application Support/Sevoflurane/Runs · sevo runs
              frame trace    every frame's time from the driver's present
                             counter, one CSV per run (Dormison).
                             Runs/traces · sevo perf
              stall watch    each process's CPU time every 2 s; 15 s with no CPU
                             and no present releases, continues, then kills the
                             game, and the record says "killed after a stall".
              crash reports  per run: Wine's exception trail, macOS .ips files,
                             Unreal, Unity and NW.js logs, Steam's logs, and a
                             manifest.json. Application Support/Sevoflurane/Reports
              known failures failures this project has diagnosed, matched to a
                             record and printed under it by sevo runs.
              event log      what the app and sevo did. Logs/Sevoflurane.log ·
                             sevo logs
              Wine log       Wine's stderr at the level's channels.
                             Logs/Sevoflurane-wine.log · sevo logs --wine
              presenter log  sevo:presenter lines in the Wine log: level 2, or
                             PresenterLog=Y under HKCU\\Software\\Wine\\Mac Driver.
            """,
        )
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            DiagCommand.report(DiagnosticLevel.current, asJSON: asJSON)
        }
    }

    /// What a level change or a status reads as, on either face.
    private static func report(_ level: DiagnosticLevel, asJSON: Bool) {
        guard !asJSON else {
            print(Sevo.json([
                "level": level.rawValue,
                "title": level.title,
                "wine_debug": level.channels(),
                "reports": CrashCollector.root.path,
                "single_run": level.isSingleRun,
            ], pretty: true))
            return
        }
        print("diagnostics \(level.summary) — \(level.detail)")
        print("reports: \(CrashCollector.root.path)")
        if level != .zero {
            print("takes effect at each game's next launch; Steam does not need restarting")
        }
    }

    /// The CLI's half of the bundle: the doctor's verdicts, the daemon's
    /// status, and the bottle's dependency state.
    static func faceReport() async -> Diagnostics.FaceReport {
        let snapshot = await Doctor.snapshot()
        let checks = Doctor.checks(from: snapshot)
        let bottleState: [String: Any] = [
            "dependencies": snapshot.dependencies,
            "provisioning": snapshot.provision.map(\.dictionary) ?? NSNull(),
        ]
        return Diagnostics.FaceReport(
            doctor: Sevo.json(Doctor.jsonReport(from: snapshot, checks: checks), pretty: true),
            status: snapshot.appStatus.map { Sevo.json($0, pretty: true) },
            bottleState: Sevo.json(bottleState, pretty: true),
            host: ["sevo": Sevo.version],
        )
    }
}
