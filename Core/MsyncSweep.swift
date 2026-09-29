import Foundation

/// msync+'s lost-wake sweep, asked of a bottle's wineserver.
///
/// A thread that dies between setting an object and waking its sleepers leaves them asleep
/// on an object that reads available; a game exiting while it signals steam.exe can leave
/// the client's main thread waiting forever. An msync+ wineserver answers `SIGUSR2` with two
/// passes 100 ms apart over every object, wakes each thread still parked on an object that
/// stayed available and unchanged between them, and writes what it found, with the processes
/// that share each object, to `<prefix>/.sevo-msync-sweep.log`. Any other wineserver dies of
/// the signal, so the sweep goes only to a server whose binary carries the sweep.
nonisolated enum MsyncSweep {
    struct Report: Sendable, Equatable {
        /// The `sevo:msync sweep …` summary line.
        var summary: String
        /// One `sevo:msync lost-wake …` line per object whose sleeper was woken, each
        /// followed by up to three recent deaths that shared it.
        var lines: [String]
        /// How many objects had a thread parked on them.
        var lostWakes: Int
    }

    enum Outcome: Sendable, Equatable {
        case swept(Report)
        /// The engine's wineserver has no sweep (CrossOver, or a Dormison before b1).
        case unsupported(String)
        case noServer
        /// The server took the signal and wrote no report within two seconds.
        case noReport
    }

    static let reportName = ".sevo-msync-sweep.log"

    /// The summary line's format string, which only a wineserver with the sweep carries.
    private static let marker = Data("sevo:msync sweep ".utf8)

    /// Whether the engine's wineserver runs the sweep.
    static func supports(_ engine: Engine) -> Bool {
        guard let binary = try? Data(contentsOf: engine.wineserverURL, options: .mappedIfSafe) else { return false }
        return binary.range(of: marker) != nil
    }

    /// Sweeps the booted bottle, or the configured one when nothing is booted.
    static func run(on target: BottleTarget = BootedBottle.target ?? .configured) async -> Outcome {
        guard supports(target.engine) else {
            return .unsupported("\(target.engine.description)'s wineserver has no lost-wake sweep")
        }
        guard let pid = await ClientLifecycle.bottleProcessIDs(matching: "wineserver", in: [target]).first else {
            return .noServer
        }
        let report = target.prefix.appending(path: reportName)
        let sent = Date.now
        guard kill(pid, SIGUSR2) == 0 else { return .noServer }
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if let parsed = read(report, writtenSince: sent) { return .swept(parsed) }
        }
        return .noReport
    }

    /// The report the server finished after `date`. It truncates the file at the first pass
    /// and writes the summary last, so a file without a summary is still being written.
    private static func read(_ url: URL, writtenSince date: Date) -> Report? {
        guard let written = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate,
            written >= date.addingTimeInterval(-0.5),
            let text = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return parse(text)
    }

    static func parse(_ text: String) -> Report? {
        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        guard let summary = lines.last(where: { $0.hasPrefix("sevo:msync sweep ") }) else { return nil }
        let lost = summary.firstMatch(of: /lost-wakes=(\d+)/).flatMap { Int($0.1) } ?? 0
        return Report(summary: summary, lines: lines.filter { $0.hasPrefix("sevo:msync lost-wake ") }, lostWakes: lost)
    }
}
