import ArgumentParser
import Foundation

struct PerfCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perf",
        abstract: "Frame-time traces of game runs: list them, compare them, chart them.",
        discussion: """
        Every run on an engine with the frame-time ring leaves a trace in \
        ~/Library/Application Support/Sevoflurane/Runs/traces (one CSV line per frame). \
        A run is named by its number in `sevo perf list` (1 is the newest), by its \
        start time as the list prints it, or by a trace file's path; a game's app id \
        names its last runs, as --game does. Runs that ran on \
        the same engine, renderer, upscaler, tuning, msync, D3DMetal, window treatment \
        and label are one configuration; repeat a configuration to make its \
        difference from another testable (Welch's t-test over the runs). With one run on a side the comparison \
        is a block bootstrap over that run's seconds, which is weaker evidence.
        
        A comparison worth reading:
          1. Play each run at least 60 s past loading, in the same scene.
          2. Change one setting between configurations; run each twice or more.
          3. Label what the record cannot see: sevo perf label 1 "vsync off".
          4. sevo perf compare --game <appid> --last <n> --skip 20
        
        A trace runs from the game's first frame to its last, menus and loading \
        included. By default each run is measured over its gameplay only, the same \
        window the run record and the community database use: from 10 s after the \
        first frame, once no frame took over 100 ms for 5 s, leaving out every \
        stretch the game was in the background, hidden, asleep or on a virtual \
        display, and every frame over 250 ms. --whole measures the whole trace. To \
        compare one pass of a benchmark, keep the same stretch of every run: --skip \
        leaves out the seconds before the pass starts and --duration keeps the seconds \
        it lasts, so --skip 45 --duration 60 compares seconds 45 to 105 of each run's \
        whole trace. compare prints each run's trace length and the stretch it compared.
        
        compare prints the first configuration as the baseline, then each other one \
        with its mean ± standard deviation over its runs (average fps, 1 % low, p99 \
        frame time) and a verdict for average and 1 % low: the change in percent, its \
        95 % interval, and the method. "higher" or "lower" means the interval \
        excludes zero; "no measurable difference" means it does not. A "Welch p" \
        is the test over runs; "block bootstrap" means a side had one run. \
        report draws the same numbers as an HTML page with the frame-time series. \
        sevo diag --help has the whole diagnostic-run guide.
        """,
        subcommands: [List.self, Report.self, Compare.self, Label.self, Mark.self],
        defaultSubcommand: List.self,
    )

    struct List: AsyncParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Runs that have a frame trace, newest first.")
        @Option(name: .long, help: "How many to list.") var last = 20
        @Option(name: .long, help: "Only this game's runs.") var game: Int?
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            let runs = PerfRuns.available(game: game).prefix(max(1, last))
            if asJSON {
                print(Sevo.json(runs.enumerated().map { PerfRuns.row($0.offset + 1, $0.element) }, pretty: true))
                return
            }
            guard !runs.isEmpty else {
                print("no runs with a frame trace yet — they come from Dormison")
                return
            }
            for (index, entry) in runs.enumerated() {
                let gameplay = entry.record.fps?.gameplay?.frameTimes
                let fps = gameplay ?? entry.record.fps?.frameTimes
                let over = gameplay != nil ? " over gameplay" : " over the whole run"
                let rates = fps.map { "\($0.avg) fps · 1 % low \($0.low1) · p99 \($0.p99) ms" + over } ?? "no frames"
                let label = entry.label.map { " · “\($0)”" } ?? ""
                print(String(format: "%3d  ", index + 1) + "\(PerfRuns.moment(entry.record.t))  "
                    + "\(entry.record.name ?? "app \(entry.record.appid)") · \(entry.record.outcome)\(label)")
                print("     \(rates)")
            }
        }
    }

    struct Selection: ParsableArguments {
        @Argument(help: """
        Runs: list numbers, start times, or trace paths; an app id means that game's last runs. \
        Default: the newest game's last runs.
        """)
        var runs: [String] = []
        @Option(name: .long, help: "With no runs named: the last N runs (of --game, else of the newest run's game).")
        var last = 6
        @Option(name: .long, help: "With no runs named: this game's runs.") var game: Int?
        @Option(name: .long, help: """
        Seconds to leave out at the start of every run: loading, shader compilation, the menus \
        before a benchmark pass. A comma list gives each run its own, in the order the runs are \
        chosen, and its last value holds for the runs after it: --skip 240,85.
        """)
        var skip = PerRunSeconds(values: [0])
        @Option(name: .long, help: "Seconds of each run to keep after --skip: the length of the pass. Default: the rest.")
        var duration: Double?
        @Flag(name: .long, help: "Measure each whole trace, loading, menus and time away included, not its gameplay.")
        var whole = false

        /// Whether runs are measured over their gameplay: nothing asked for a stretch of
        /// the whole trace.
        var gameplay: Bool {
            !whole && fromMark == nil && duration == nil && skip.values.allSatisfy { $0 == 0 }
        }
        @Option(name: .customLong("from-mark"), help: """
        Start each run at its first mark with this label (sevo perf mark), in place of --skip. \
        A run without one is named and left out.
        """)
        var fromMark: String?

        func resolve() throws -> [PerfComparison.Run] {
            let available = PerfRuns.available(game: nil)
            func lastRuns(of appID: Int?) -> [PerfRuns.Entry] {
                Array(available.filter { $0.record.appid == appID }.prefix(max(1, last)).reversed())
            }
            var chosen: [PerfRuns.Entry] = []
            if runs.isEmpty {
                chosen = lastRuns(of: game ?? available.first?.record.appid)
            } else {
                for reference in runs {
                    if let entry = PerfRuns.find(reference, in: available) {
                        chosen.append(entry)
                    } else if let appID = Int(reference), available.contains(where: { $0.record.appid == appID }) {
                        // Past the end of the list, a number that names a game with traces is
                        // that game: people reach for the app id they launch it by.
                        Sevo.printError("\(reference) is app \(appID)'s id: comparing its last runs, as --game \(appID)")
                        chosen += lastRuns(of: appID)
                    } else {
                        throw ValidationError(
                            "no run \(reference) — sevo perf list names them; a game's runs are --game <appid>",
                        )
                    }
                }
            }
            guard !chosen.isEmpty else { throw ValidationError("no runs with a frame trace") }
            return chosen.enumerated().compactMap { position, entry in
                guard let contents = FrameTrace.read(entry.url) else { return nil }
                var skip = PerfComparison.skip(skip.values, forRun: position)
                if let fromMark {
                    guard let mark = contents.marks.first(where: { $0.label == fromMark }) else {
                        Sevo.printError("\(PerfRuns.moment(entry.record.t)) has no mark “\(fromMark)”: left out")
                        return nil
                    }
                    skip = mark.seconds
                }
                let total = Self.seconds(contents.frameTimes)
                if gameplay {
                    guard let window = GameplayWindow.compute(contents), window.frameTimes.count >= 2 else {
                        Sevo.printError(
                            "\(PerfRuns.moment(entry.record.t)) never settled into gameplay: left out (--whole keeps it)",
                        )
                        return nil
                    }
                    return PerfComparison.Run(
                        record: entry.record, frameTimes: window.frameTimes, dropped: contents.dropped,
                        trace: entry.url.lastPathComponent, label: entry.label,
                        traceSeconds: total, window: window.from ... max(window.from, total),
                        leftOut: PerfComparison.leftOut(window),
                    )
                }
                let times = PerfComparison.trim(contents.frameTimes, skip: skip, duration: duration)
                guard times.count >= 2 else { return nil }
                let from = min(skip, total)
                return PerfComparison.Run(
                    record: entry.record, frameTimes: times, dropped: contents.dropped,
                    trace: entry.url.lastPathComponent, label: entry.label,
                    traceSeconds: total, window: from ... from + Self.seconds(times),
                )
            }
        }

        /// How long a run of frames lasts, in seconds.
        private static func seconds(_ times: [Float]) -> Double {
            times.reduce(0.0) { $0 + Double($1) } / 1000
        }
    }

    struct Report: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Chart runs in one HTML page: frame times, frame rate, percentiles, and the comparison.",
        )
        @OptionGroup var selection: Selection
        @Option(name: [.short, .long], help: "Where to write the page. Default: Runs/reports/<time>.html.")
        var output: String?
        @Flag(name: .long, help: "Open the page when it is written.") var open = false

        func run() async throws {
            let runs = try selection.resolve()
            let html = PerfReport.html(
                runs: runs, skip: selection.skip.values, fromMark: selection.fromMark, duration: selection.duration,
                gameplay: selection.gameplay,
            )
            let url = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
                ?? RunLog.root.appendingPathComponent("reports")
                .appendingPathComponent("perf-\(runRecordStamp.string(from: .now).replacingOccurrences(of: ":", with: "-")).html")
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data(html.utf8).write(to: url, options: .atomic)
            print(url.path)
            if open { NSWorkspaceOpen.open(url) }
        }
    }

    struct Compare: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "The comparison as text: each configuration against the first, with 95 % intervals.",
        )
        @OptionGroup var selection: Selection
        @Flag(name: .customLong("json")) var asJSON = false

        func run() async throws {
            let groups = try PerfComparison.groups(selection.resolve())
            if asJSON {
                print(Sevo.json(PerfReport.model(groups, series: false), pretty: true))
                return
            }
            for line in PerfReport.textLines(groups) { print(line) }
            if selection.whole, selection.skip.values.allSatisfy({ $0 == 0 }), selection.fromMark == nil,
               selection.duration == nil {
                print("whole runs compared, loading and menus included; "
                    + "--skip and --duration keep the same stretch of each (sevo perf --help)")
            }
        }
    }

    struct Label: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Name a run, so runs the record cannot tell apart compare as different configurations.",
        )
        @Argument(help: "The run: a list number, a start time, or a trace path.") var reference: String
        @Argument(help: "The label; empty removes it.") var label: String

        func run() async throws {
            guard let entry = PerfRuns.find(reference, in: PerfRuns.available(game: nil)) else {
                throw ValidationError("no run \(reference) — sevo perf list names them")
            }
            try PerfLabels.set(label, forTrace: entry.url.lastPathComponent)
            print(label.isEmpty ? "label removed" : "labeled “\(label)”")
        }
    }
}

extension PerfCommand {
    struct Mark: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Name this moment in every running game's trace, for compare --from-mark.",
            discussion: """
            A harness calls it where a benchmark pass starts, so runs line up on the pass \
            itself rather than on a guessed --skip.
            """,
        )
        @Argument(help: "The mark's label.") var label = "mark"

        func run() async throws {
            let query = label.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            guard let reply = await AppControl.appLinkPost("/perf/mark?label=\(query)", timeout: 10) else {
                throw ValidationError("Sevoflurane is not running, so no trace is being written")
            }
            guard reply.status == 200 else {
                throw ValidationError("the running Sevoflurane does not take marks (HTTP \(reply.status)); it predates them")
            }
            let marked = (Sevo.jsonObject(String(decoding: reply.body, as: UTF8.self))?["marked"] as? Int) ?? 0
            print(marked == 0 ? "no run is being traced: nothing marked"
                : "marked “\(label)” in \(marked) trace\(marked == 1 ? "" : "s")")
        }
    }
}

/// `--skip`'s seconds, one per chosen run or one for all.
struct PerRunSeconds: ExpressibleByArgument {
    var values: [Double]

    init(values: [Double]) {
        self.values = values
    }

    init?(argument: String) {
        guard let values = PerfComparison.skips(parsing: argument) else { return nil }
        self.values = values
    }

    var defaultValueDescription: String {
        values.map { String(format: "%g", $0) }.joined(separator: ",")
    }
}

/// The runs that have a trace on disk.
nonisolated enum PerfRuns {
    struct Entry: Sendable {
        var record: RunRecord
        var url: URL
        var label: String?
    }

    /// Newest first.
    static func available(game: Int?) -> [Entry] {
        let labels = PerfLabels.all()
        let directory = FrameTrace.directory()
        return RunLog.recent(2000).reversed().compactMap { record in
            guard let name = record.fps?.trace, game == nil || record.appid == game else { return nil }
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            return Entry(record: record, url: url, label: labels[name])
        }
    }

    static func find(_ reference: String, in entries: [Entry]) -> Entry? {
        if let number = Int(reference), number >= 1, number <= entries.count { return entries[number - 1] }
        let path = (reference as NSString).expandingTildeInPath
        if path.hasSuffix(".csv") {
            return entries.first { $0.url.lastPathComponent == (path as NSString).lastPathComponent }
        }
        return entries.first { moment($0.record.t).hasPrefix(reference) || $0.record.t.hasPrefix(reference) }
    }

    static func row(_ number: Int, _ entry: Entry) -> [String: Any] {
        var row: [String: Any] = [
            "number": number, "t": entry.record.t, "appid": entry.record.appid,
            "name": entry.record.name ?? "", "engine": entry.record.engine,
            "renderer": entry.record.renderer, "trace": entry.url.path,
        ]
        if let label = entry.label { row["label"] = label }
        if let summary = entry.record.fps?.frameTimes,
           let data = try? JSONEncoder().encode(summary),
           let object = try? JSONSerialization.jsonObject(with: data) {
            row["frame_times"] = object
        }
        return row
    }

    /// A record's UTC stamp in this Mac's time, to the second.
    static func moment(_ stamp: String) -> String {
        guard let date = runRecordStamp.date(from: stamp) else { return stamp }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd HH:mm:ss"
        local.locale = Locale(identifier: "en_US_POSIX")
        return local.string(from: date)
    }
}

/// `open` without AppKit, which the CLI does not link.
nonisolated enum NSWorkspaceOpen {
    static func open(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.path]
        try? process.run()
    }
}
