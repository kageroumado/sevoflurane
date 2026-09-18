import ArgumentParser
import Foundation

/// `sevo diag`: what a bug report needs, in one zip on the Desktop.
struct DiagCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diag",
        abstract: "Write a zip of the logs, a doctor report and the engine's identity, for a bug report.",
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
        Diagnostics.faceReport = { await Self.faceReport() }
        let destination = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let zip = try await Diagnostics.bundle(to: destination, steamLogs: steamLogs)
        print(asJSON ? Sevo.json(["path": zip.path]) : zip.path)
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
