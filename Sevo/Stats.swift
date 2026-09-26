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
        
        Local state lives in ~/Library/Application Support/Sevoflurane/Stats. `sevo stats \
        delete` takes back everything this Mac shared, as Settings › General › Community › \
        Delete What I Shared does.
        """,
        subcommands: [Status.self, Preview.self, Delete.self],
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
            let sharing = StatsDeletionReport.sharingWord(Preferences.sharesRunStats)
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

    struct Delete: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Delete every run this Mac shared from the community database. Cannot be undone.",
            discussion: """
            Sends the install's signed request to delete it, then drops this Mac's key, \
            registration and unsent runs, as Settings › General › Community › Delete What I \
            Shared does. The sharing setting is left as it is: while it is on, the next run \
            shared registers a new, unrelated install. A refused or unsent request changes \
            nothing here and exits 1.
            """,
        )

        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            let queued = StatsStore.readQueue().count
            let outcome: Result<StatsUploader.DeleteOutcome, any Error>
            do {
                outcome = try await .success(StatsUploader.shared.deleteShared())
            } catch {
                outcome = .failure(error)
            }
            let report = StatsDeletionReport(outcome: outcome, sharing: Preferences.sharesRunStats, queued: queued)
            print(asJSON ? Sevo.json(report.json) : report.text)
            if !report.succeeded { throw SevoExit.failed }
        }
    }
}
