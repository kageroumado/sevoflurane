import ArgumentParser
import Foundation

/// `sevo diag`: what a bug report needs, in one zip on the Desktop — and the
/// level the next game runs at.
struct DiagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag",
        abstract: "The zip a bug report needs, and how much the next run records.",
        subcommands: [Save.self, On.self, Off.self, Status.self],
        defaultSubcommand: Save.self,
    )

    /// `sevo diag` with no subcommand, which is what every script that
    /// predates the levels calls.
    struct Save: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "save",
            abstract: "Write a zip of the logs, a doctor report and the engine's identity.",
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
