import Foundation

/// What the Wine log gained during a run, read for the two things it can say
/// on its own: an unhandled exception, and the renderer complaining.
nonisolated enum WineExceptionTrail {
    /// The last unhandled exception in the text — the one that ended the
    /// process, since Wine terminates it on the spot.
    static func lastException(in text: String) -> RunRecord.Crash? {
        ending(in: text, forProcesses: []).crash
    }

    /// How a run's game ended, as the Wine log tells it.
    struct Ending: Equatable {
        /// The unhandled exception that ended the game.
        var crash: RunRecord.Crash?
        /// The exception came while the game had no window left: the user had
        /// already left it, and it fell over on the way out.
        var afterWindowsClosed = false
    }

    /// The game's own last unhandled exception, and whether it came while the
    /// game had closed its windows.
    ///
    /// The engine writes `sevo:exit pid=<unix pid> wpid=<wine pid> windows
    /// closed` each time a process that presented is left with no on-screen
    /// window, and `… windows reopened` when it shows one again (a game can
    /// hide its only window for a mode switch). When one of `processes` (the
    /// game's unix pids) wrote either, only exceptions of those Wine pids
    /// count: a crash reporter or launcher falling over during the run is not
    /// the game crashing. The exception is on the way out when the last of
    /// those lines before it says `closed`. An engine without the lines, or a
    /// game that never wrote one, leaves the last exception of any process.
    static func ending(in text: String, forProcesses processes: Set<Int>) -> Ending {
        // Per game Wine pid: whether its windows are closed at this point of the log.
        var closed: [Int: Bool] = [:]
        var exceptions: [(winePID: Int?, closed: Bool, crash: RunRecord.Crash)] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: unhandled) {
                let winePID = line.firstMatch(of: winePrefix).flatMap { Int($0.output.1, radix: 16) }
                exceptions.append((winePID, winePID.flatMap { closed[$0] } ?? false, RunRecord.Crash(
                    code: "0x\(match.output.1)",
                    flags: "0x\(match.output.2)",
                    address: String(match.output.3),
                    module: nil,
                )))
            } else if line.hasPrefix("sevo:exit"), let match = line.firstMatch(of: windowsEdge),
                      let pid = Int(match.output.1), processes.contains(pid),
                      let winePID = Int(match.output.2, radix: 16) {
                closed[winePID] = match.output.3 == "closed"
            }
        }
        guard !closed.isEmpty else { return Ending(crash: exceptions.last?.crash) }
        guard let last = exceptions.last(where: { $0.winePID.map { closed[$0] != nil } ?? false })
        else { return Ending() }
        return Ending(crash: last.crash, afterWindowsClosed: last.closed)
    }

    /// The renderer's own complaints, deduplicated with a count. DXMT writes
    /// these whatever `WINEDEBUG` says, and each one is a Direct3D call that
    /// did not do what the game asked.
    static func notes(in text: String) -> [String] {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let marker = markers.first(where: { line.contains($0) }) else { continue }
            let note = String(
                line[(line.range(of: marker)?.lowerBound ?? line.startIndex)...],
            ).trimmingCharacters(in: .whitespaces)
            if counts[note] == nil { order.append(note) }
            counts[note, default: 0] += 1
        }
        return order.prefix(maximumNotes).map { note in
            let count = counts[note] ?? 1
            return count > 1 ? "\(note) ×\(count)" : note
        }
    }

    private static let markers = ["Not supported feature:", "Shader not found?"]
    private static let maximumNotes = 8

    /// `dlls/ntdll/unix/thread.c`'s last word before it terminates the
    /// process; `err:seh` is in the always-on channels.
    private nonisolated(unsafe) static let unhandled =
        /Unhandled exception code ([0-9a-fA-F]+) flags ([0-9a-fA-F]+) addr (0x[0-9a-fA-F]+)/
    /// The `+pid` channel's prefix, `0288:0214:err:…`: the Wine process, then the thread.
    private nonisolated(unsafe) static let winePrefix = /^([0-9a-fA-F]{4,8}):[0-9a-fA-F]{4,8}:/
    private nonisolated(unsafe) static let windowsEdge =
        /sevo:exit pid=(\d+) wpid=([0-9a-fA-F]+) windows (closed|reopened)/
}
