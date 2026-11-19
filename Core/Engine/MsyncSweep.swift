import Foundation

/// msync+'s lost-wake sweep, asked of a bottle's wineserver.
///
/// A thread that dies between setting an object and waking its sleepers leaves them parked
/// on an object that reads available, such as steam.exe's main thread after a game exits.
/// An msync+ wineserver answers `SIGUSR2` with two passes 100 ms apart, wakes each thread
/// parked on an object that stayed available and unchanged, and writes its findings to
/// `<prefix>/.sevo-msync-sweep.log`. Any other wineserver dies of the signal.
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

    /// Present only in the binary of a wineserver with the sweep.
    private static let marker = Data("sevo:msync sweep ".utf8)

    static func supports(_ engine: Engine) -> Bool {
        supports(binaryAt: engine.wineserverURL)
    }

    static func supports(binaryAt url: URL) -> Bool {
        guard let binary = try? Data(contentsOf: url, options: .mappedIfSafe) else { return false }
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
        // The running server, which can be another engine's after a switch that
        // waits for a restart: one without the sweep dies of the signal.
        guard let running = WineOrphans.executablePath(of: pid),
              supports(binaryAt: URL(fileURLWithPath: running)) else {
            return .unsupported("the running wineserver has no lost-wake sweep")
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

    /// The report the server finished after `date`; the summary line is written
    /// last, so a file without one is still being written.
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
