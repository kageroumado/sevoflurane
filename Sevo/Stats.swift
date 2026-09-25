import ArgumentParser
import Foundation

/// `sevo stats`: the community database from this Mac's side — whether runs
/// are shared, what waits to go, and exactly what a run sends.
struct StatsCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "What this Mac shares with the community game database.",
        discussion: """
        With sharing on (Settings › General › Community), every game run that drew a frame or \
        lasted 20 seconds goes to the public Sevoflurane game database after it closes: the \
        appid, executable name, engine, renderer, settings, resolution, frame rates, and the \
        Mac's model, chip, GPU cores and memory tier. Requests are signed by a key in this Mac's \
        Secure Enclave; the install id is derived from that key and names nothing else.
        
        Local state lives in ~/Library/Application Support/Sevoflurane/Stats.
        """,
        subcommands: [Status.self, Preview.self],
        defaultSubcommand: Status.self,
    )

    struct Status: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Whether runs are shared, the install id, and what waits to be sent.",
        )

        @Flag(name: .customLong("json")) var asJSON = false

        func run() throws {
            let state = StatsStore.readState()
            let queued = StatsStore.readQueue().count
            let sharing = switch Preferences.sharesRunStats {
            case true?: "on"
            case false?: "off"
            case nil: "not asked yet"
            }
            if asJSON {
                var report: [String: Any] = ["sharing": sharing, "queued": queued, "sent": state.sentRuns]
                report["install"] = state.registered
                report["trust"] = state.trust
                report["last_sent"] = state.lastSent.map { ISO8601DateFormatter().string(from: $0) }
                report["last_error"] = state.lastError
                print(Sevo.json(report))
                return
            }
            print("sharing    \(sharing)")
            print("install    \(state.registered.map { "\($0) (\(state.trust ?? "unverified"))" } ?? "not registered")")
            print("queued     \(queued)")
            print("sent       \(state.sentRuns)\(state.lastSent.map { ", last \($0.formatted())" } ?? "")")
            if let error = state.lastError { print("last error \(error)") }
        }
    }

    struct Preview: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Print exactly what the last recorded run would send, as JSON.",
            discussion: "Runs that never drew and lasted under 20 seconds are never sent; for those this says so.",
        )

        func run() throws {
            guard let record = RunLog.recent(1).last else {
                print("no runs recorded yet")
                return
            }
            guard let run = SharedRun(record: record, appVersion: String(Sevo.version.prefix { $0 != " " })) else {
                print("the last run (\(record.appid)) would not be sent: it never drew and lasted under 20 seconds")
                return
            }
            print(run.json)
        }
    }
}
