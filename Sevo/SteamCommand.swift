import ArgumentParser
import Foundation

/// `sevo steam` — Steam's client as the app depends on it.
struct SteamCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "steam",
        abstract: "Steam's client as the app depends on it.",
        subcommands: [Audit.self],
    )

    /// Reads a client's `steamui` files and answers for every entry of
    /// ``SteamSurface``. Nothing is started and nothing in the folder is run,
    /// so it checks a client that is not installed as readily as the bottle's.
    struct Audit: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "audit",
            abstract: "Check a Steam client's files for everything the app depends on in Steam's UI.",
            discussion: """
            Prints one line for each dependency that is missing or changed, then the totals. \
            Exits 1 when anything is missing. With --json, every entry's answer.
            """,
        )

        @Option(name: .customLong("bundle"), help: "A steamui folder. The bottle's own when left out.")
        var bundle: String?

        @Flag(name: .customLong("json"), help: "Every entry's answer as JSON.")
        var asJSON = false

        func run() async throws {
            let folder = bundle.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? SteamBottle.steamui
            let files: SteamUIBundle
            do {
                files = try SteamUIBundle(folder: folder)
            } catch {
                Sevo.printError("no Steam UI scripts in \(folder.path)")
                throw bundle == nil ? SevoExit.notProvisioned : SevoExit.badInvocation
            }
            let report = SteamSurface.audit(files, at: folder.path)
            if asJSON {
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
                try print(String(decoding: encoder.encode(report), as: UTF8.self))
            } else {
                report.lines.forEach { print($0) }
            }
            if report.missing > 0 { throw SevoExit.failed }
        }
    }
}
