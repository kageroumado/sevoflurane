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
        subcommands: [Status.self, Preview.self, Reports.self, Delete.self],
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
            let queuedReports = StatsStore.readReportQueue().count
            let sentReports = state.sentReports ?? 0
            let sharing = StatsDeletionReport.sharingWord(Preferences.sharesRunStats)
            if asJSON {
                var report: [String: Any] = [
                    "sharing": sharing, "queued": queued, "sent": state.sentRuns,
                    "queued_reports": queuedReports, "sent_reports": sentReports,
                ]
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
            print("reports    \(queuedReports) queued, \(sentReports) sent")
            if let error = state.lastError { print("last error \(error)") }
        }
    }

    struct Reports: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Every run this Mac reported on, with its verdict and whether the report went.",
            discussion: "`sevo report` writes one; the Reports window's \"How did it go?\" writes the same.",
        )

        @Flag(name: .customLong("json")) var asJSON = false

        func run() throws {
            let reported = StatsStore.readReported()
            if asJSON {
                print(Sevo.json(reported.map(Self.row), pretty: true))
                return
            }
            guard !reported.isEmpty else {
                print("no reports yet — sevo report <appid> --verdict plays writes one")
                return
            }
            for entry in reported {
                print("\(entry.runID)  \(entry.verdict.rawValue)  \(Self.standing(entry))")
            }
        }

        static func row(_ entry: StatsStore.Reported) -> [String: Any] {
            var row: [String: Any] = [
                "run": entry.runID, "verdict": entry.verdict.rawValue,
                "queued": ISO8601DateFormatter().string(from: entry.queued), "state": standing(entry),
            ]
            row["sent"] = entry.sent.map { ISO8601DateFormatter().string(from: $0) }
            row["refused"] = entry.refused
            return row
        }

        static func standing(_ entry: StatsStore.Reported) -> String {
            if let refused = entry.refused { return "refused: \(refused)" }
            return entry.sent == nil ? "queued" : "sent"
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

/// `sevo report`: what a person says about a run, for the community database.
struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report",
        abstract: "Tell the community game database how a game ran: a verdict and an optional note.",
        discussion: """
        The verdict is ProtonDB's ladder in four steps: plays (nothing to do), plays-with-fixes \
        (the note says which), launches (menu or first frames, then trouble), fails (no window, or \
        dies at start). The run's engine, renderer, settings, macOS and chip are attached from its \
        record; the note is the one thing typed, and it is public — plain text, at most 600 \
        characters, no paths or e-mail addresses.
        
        Only with sharing on (Settings › General › Community). The report is queued beside the \
        shared runs and sent at once when this Mac is registered with the database; otherwise the \
        app sends it after its next shared run registers.
        """,
    )

    @Argument(help: "A Steam appid, for its newest run, or a run id as `sevo runs --json` prints it (appid-t).")
    var run: String
    @Option(name: .customLong("verdict"), help: "plays, plays-with-fixes, launches or fails.")
    var verdict: SharedReport.Verdict
    @Option(name: .customLong("note"), help: "At most 600 characters of plain text.")
    var note = ""
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        guard let record = RunRecord.matching(run, in: RunLog.recent(2000)) else {
            Sevo.printError("no run matches \(run) — sevo runs lists them")
            throw SevoExit.badInvocation
        }
        guard Preferences.sharesRunStats == true else {
            Sevo.printError("sharing is off; turn it on in Settings › General › Community to send reports")
            throw SevoExit.failed
        }
        if let problem = SharedReport.noteProblem(note, verdict: verdict) {
            Sevo.printError(problem.sentence)
            throw SevoExit.badInvocation
        }
        if let already = StatsStore.reported(forRun: record.id) {
            Sevo.printError("run \(record.id) was already reported as \(already.verdict.rawValue) on \(already.queued.formatted())")
            throw SevoExit.failed
        }
        let report = SharedReport(record: record, verdict: verdict, note: note)
        StatsStore.noteReported(StatsStore.Reported(runID: record.id, verdict: verdict, queued: .now))
        StatsUploader.log = { Sevo.printError($0) }
        await StatsUploader.shared.enqueue(report, forRun: record.id)
        // Registering is the app's to do: it holds the App Attest evidence a
        // registration from here would lack.
        if StatsStore.readState().registered != nil {
            await StatsUploader.shared.flush()
        }
        let standing = StatsStore.reported(forRun: record.id)
        if asJSON {
            var row = standing.map(StatsCommand.Reports.row) ?? [:]
            row["report"] = Sevo.jsonObject(report.json)
            print(Sevo.json(row, pretty: true))
            return
        }
        print(record.summary)
        print("reported as \(verdict.rawValue): \(standing.map(StatsCommand.Reports.standing) ?? "queued")")
    }
}

extension SharedReport.Verdict: ExpressibleByArgument {}
