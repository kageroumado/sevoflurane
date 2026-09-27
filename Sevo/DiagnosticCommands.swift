import ArgumentParser
import Foundation

// MARK: - debug channels

struct HoldsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "holds",
        abstract: "What keeps this Mac's display awake, and which of it is Sevoflurane's.",
        discussion: """
        Every power assertion that stops the display sleeping, oldest first, with the \
        process it counts against — a bottle process by its Windows program. Sevoflurane's \
        own are marked. Exit status is 1 when one of ours stands while no game run is open.
        """,
    )

    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let holds = DisplayHolds.current()
        let runOpen = !RunLog.armedRuns().isEmpty
        if asJSON {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try print(String(decoding: encoder.encode(holds), as: UTF8.self))
        } else if holds.isEmpty {
            print("nothing holds the display awake")
        } else {
            for hold in holds { print("\(hold.isOurs ? "*" : " ") \(DisplayHolds.describe(hold))") }
            if holds.contains(where: \.isOurs) { print("* Sevoflurane's" + (runOpen ? " — a game run is open" : " — no game run is open")) }
        }
        if !runOpen, holds.contains(where: \.isOurs) { throw SevoExit.failed }
    }
}

struct OrphansCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "orphans",
        abstract: "Wine processes of Sevoflurane's engines whose wineserver is gone.",
        discussion: """
        A Wine process cannot do anything once its prefix's wineserver has died; one \
        that does not notice stays parked until something ends it. The helper ends \
        these on its own after two sightings a minute apart; --end does it now. Exit \
        status is 1 when any were found and left running.
        """,
    )

    @Flag(name: .customLong("end"), help: "End every one found (SIGKILL).") var end = false
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        let found = WineOrphans.find()
        let ended = end ? WineOrphans.end(found) : []
        if asJSON {
            let rows = found.map { orphan -> [String: Any] in
                [
                    "pid": Int(orphan.pid),
                    "prefix": orphan.prefix,
                    "command": orphan.command,
                    "executable": orphan.executable,
                    "ended": ended.contains(orphan),
                ]
            }
            print(Sevo.json(rows, pretty: true))
        } else if found.isEmpty {
            print("no orphaned Wine processes")
        } else {
            for (prefix, group) in Dictionary(grouping: found, by: \.prefix).sorted(by: { $0.key < $1.key }) {
                print("\((prefix as NSString).abbreviatingWithTildeInPath) — \(group.count) without a wineserver")
                for orphan in group.prefix(8) { print("    \(orphan.pid)  \(orphan.command)") }
                if group.count > 8 { print("    … \(group.count - 8) more") }
            }
            print(end ? "ended \(ended.count)" : "end them with: sevo orphans --end")
        }
        if !found.isEmpty, !end { throw SevoExit.failed }
    }
}

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

/// `sevo runs`: what every game launch did, from the run records.
struct RunsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "runs",
        abstract: "The last game launches: what each ran on, how long, and how it ended.",
        discussion: """
        One line per launch, oldest first, with the recognized failure beneath \
        the ones the app knows. Records live in ~/Library/Application \
        Support/Sevoflurane/Runs, one JSON Lines file per month.
        
        A record is written for every launch at every diagnostic level: the \
        engine, renderer, tuning and upscaler it ran on, when its first window \
        appeared, how long it ran, how it ended, the last exception in the Wine \
        log, the renderer's notes, and the frame-rate summary (average, 1 % low, \
        percentiles, hitches). --json adds known_failure where the app \
        recognizes the ending. A run with no window and a short duration is a \
        start-up failure; a collected report, when the run has one, is under \
        Application Support/Sevoflurane/Reports. sevo diag --help says how to \
        make a run worth reading.
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
    static func row(_ record: RunRecord) -> [String: Any] {
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
        guard let existing = LogTail.lastLines(of: file, count: max(1, lines)),
              let handle = try? FileHandle(forReadingFrom: file) else {
            Sevo.printError("no log file at \(file.path) — has the app ever run?")
            throw SevoExit.failed
        }
        for line in existing {
            print(line)
        }
        guard follow else { return }
        var offset = (try? handle.seekToEnd()) ?? 0
        while true {
            try? await Task.sleep(for: .milliseconds(500))
            // Rotation copies the log aside and truncates it in place, so a
            // file shorter than what was read has started over.
            let size = (try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? UInt64 ?? offset
            if size < offset {
                offset = 0
                try? handle.seek(toOffset: 0)
            }
            if let data = try? handle.readToEnd(), !data.isEmpty {
                offset += UInt64(data.count)
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
            guard let reply = await DebugCommand.ask("/debug/on", method: "POST") else {
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
            if let reply = await DebugCommand.ask("/debug/off", method: "POST") {
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
            if let reply = await DebugCommand.ask("/debug", method: "GET") {
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

    /// The app's answer to one debug verb, through the helper and else from
    /// the app's own link port. The helper is silent while it is being
    /// replaced, and an app it has not heard from yet is still the one that
    /// owns the switch. `nil` only when no app answers on either port.
    fileprivate static func ask(_ path: String, method: String) async -> Data? {
        let isRead = method == "GET"
        if let viaHelper = isRead ? await AppControl.get(path) : await AppControl.post(path) {
            return viaHelper
        }
        let direct = isRead
            ? await AppControl.appLinkGet(path)
            : await AppControl.appLinkPost(path, timeout: 10)
        guard let direct, (200 ..< 300).contains(direct.status) else { return nil }
        return direct.body
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
