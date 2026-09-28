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
        /// The last `sevo:exit … windows` line of the game's processes says
        /// `closed`: whatever ended the game came after the user left it.
        var windowsClosedAtEnd = false
    }

    /// The game's own last unhandled exception, and whether it came while the
    /// game had closed its windows.
    ///
    /// Three lines name an exception, read in this order of trust:
    ///
    /// - `sevo:crash wpid=<wine pid> code=<status> addr=<address> module=<name>`,
    ///   which the engine writes once per crashing process as the exception
    ///   reaches `UnhandledExceptionFilter`, before the game's own filter
    ///   (Unity's, Unreal's, Mono's) gets to exit with a plain status. It is
    ///   the game's when its Wine pid is one of `winePIDs` (the `wpid=` of the
    ///   game's `sevo:run` lines) or of a game process's `sevo:exit` lines;
    ///   with neither known, the last one is taken as the game's.
    /// - `err:seh … Unhandled exception code … flags … addr …`, Wine's
    ///   last-chance handler.
    /// - `wine: Unhandled page fault … at address 0x…` and its siblings,
    ///   written as Wine starts the debugger. It names no process.
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
    static func ending(
        in text: String, forProcesses processes: Set<Int>, winePIDs: Set<Int> = [],
    ) -> Ending {
        // Per game Wine pid: whether its windows are closed at this point of the log.
        var closed: [Int: Bool] = [:]
        var lastEdgeClosed = false
        var exceptions: [Exception] = []
        var reported: [Exception] = []
        for line in text.split(whereSeparator: \.isNewline) {
            if let match = line.firstMatch(of: reportedCrash) {
                let winePID = Int(match.output.1, radix: 16)
                let module = match.output.4.trimmingCharacters(in: .whitespaces)
                reported.append(Exception(
                    winePID: winePID, closed: winePID.flatMap { closed[$0] } ?? false,
                    crash: RunRecord.Crash(
                        code: "0x\(match.output.2.lowercased())",
                        flags: nil,
                        address: address(match.output.3),
                        module: module.isEmpty || module == "?" ? nil : module,
                    ),
                ))
            } else if let match = line.firstMatch(of: unhandled) {
                let winePID = line.firstMatch(of: winePrefix).flatMap { Int($0.output.1, radix: 16) }
                exceptions.append(Exception(
                    winePID: winePID, closed: winePID.flatMap { closed[$0] } ?? false,
                    crash: RunRecord.Crash(
                        code: "0x\(match.output.1)",
                        flags: "0x\(match.output.2)",
                        address: String(match.output.3),
                        module: nil,
                    ),
                ))
            } else if let crash = debuggerCrash(in: line) {
                exceptions.append(Exception(winePID: nil, closed: false, crash: crash))
            } else if line.hasPrefix("sevo:exit"), let match = line.firstMatch(of: windowsEdge),
                      let pid = Int(match.output.1), processes.contains(pid),
                      let winePID = Int(match.output.2, radix: 16) {
                closed[winePID] = match.output.3 == "closed"
                lastEdgeClosed = closed[winePID] ?? false
            }
        }
        let gameWinePIDs = winePIDs.union(closed.keys)
        let ownReport = gameWinePIDs.isEmpty
            ? reported.last
            : reported.last { report in report.winePID.map { gameWinePIDs.contains($0) } ?? false }
        if let ownReport {
            return Ending(
                crash: ownReport.crash, afterWindowsClosed: ownReport.closed, windowsClosedAtEnd: lastEdgeClosed,
            )
        }
        guard !closed.isEmpty else { return Ending(crash: exceptions.last?.crash) }
        guard let last = exceptions.last(where: { $0.winePID.map { closed[$0] != nil } ?? false })
        else { return Ending(windowsClosedAtEnd: lastEdgeClosed) }
        return Ending(crash: last.crash, afterWindowsClosed: last.closed, windowsClosedAtEnd: lastEdgeClosed)
    }

    /// One exception line: the Wine process it came from when the line names
    /// one, and whether that process's windows were closed when it came.
    private struct Exception {
        var winePID: Int?
        var closed: Bool
        var crash: RunRecord.Crash
    }

    /// The exception in a `wine: Unhandled … at address 0x… (thread …),
    /// starting debugger...` line, with the status that `format_exception_msg`
    /// in `kernelbase/debug.c` spells out in words.
    static func debuggerCrash(in line: some StringProtocol) -> RunRecord.Crash? {
        guard let match = String(line).firstMatch(of: debuggerMessage) else { return nil }
        let code = match.output.2.map { "0x\($0.lowercased())" }
            ?? debuggerStatuses.first { match.output.1.hasPrefix($0.words) }?.code
        return code.map { RunRecord.Crash(code: $0, flags: nil, address: String(match.output.3), module: nil) }
    }

    /// The words `format_exception_msg` gives each status it names.
    private static let debuggerStatuses: [(words: String, code: String)] = [
        ("page fault", "0xc0000005"),
        ("stack overflow", "0xc00000fd"),
        ("illegal instruction", "0xc000001d"),
        ("privileged instruction", "0xc0000096"),
        ("division by zero", "0xc0000094"),
        ("overflow", "0xc0000095"),
        ("array bounds", "0xc000008c"),
        ("alignment", "0x80000002"),
    ]

    /// `sevo:crash` prints the address as bare, zero-padded hex; the record
    /// keeps the `0x…` form Wine's own lines use.
    private static func address(_ digits: Substring) -> String {
        let bare = digits.lowercased().drop { $0 == "0" }
        return "0x" + (bare.isEmpty ? "0" : bare)
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
    /// The engine's own line for a crashing process, one per process.
    private nonisolated(unsafe) static let reportedCrash =
        /sevo:crash wpid=([0-9a-fA-F]+) code=([0-9a-fA-F]{8}) addr=(?:0x)?([0-9a-fA-F]+) module=(.*)$/
    /// `kernelbase`'s `wine: %s (thread %04lx), starting debugger...`, for the
    /// statuses that end a process.
    private nonisolated(unsafe) static let debuggerMessage =
        /wine: Unhandled (page fault|stack overflow|illegal instruction|privileged instruction|division by zero|overflow|array bounds|alignment|exception 0x([0-9a-fA-F]{8}))\b.*? at address (0x[0-9a-fA-F]+)/
    private nonisolated(unsafe) static let windowsEdge =
        /sevo:exit pid=(\d+) wpid=([0-9a-fA-F]+) windows (closed|reopened)/
}
