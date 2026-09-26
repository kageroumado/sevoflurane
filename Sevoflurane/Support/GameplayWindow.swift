import Foundation

/// The frames of a run that were gameplay: what a frame rate is measured over.
///
/// A trace runs from the game's first frame to its last, and most of what lies at either
/// side of play is not play. A game presents its loading screens at a few frames a second
/// with gaps of seconds between them, many games drop to a trickle or stop presenting when
/// their window is not the focused one, and a display that sleeps stops them outright. An
/// average over all of that describes the loading screen and the time the player was
/// away, not the game. So the window, from a trace alone (``FrameTrace/Contents``):
///
/// 1. **Start.** Gameplay begins at the first frame at least ``Rules/warmup`` after the
///    trace's first frame from which ``Rules/steady`` seconds pass with no frame slower than
///    ``Rules/steadyFrame``: loading is over once frames come steadily. A run that never
///    settles starts at ``Rules/settleLimit`` regardless, so a game that stutters all the
///    way through still gets measured, stutter included.
/// 2. **Away.** Frames while the app saw the window in the background, hidden or asleep
///    (``FrameTrace/Focus``), or on a virtual display, are left out, and so are the
///    ``Rules/focusGuard`` seconds before each such change: the app looks every two seconds,
///    so the change happened up to that long before it was written.
/// 3. **Gaps.** A frame slower than ``Rules/gapFrame`` after the start is a pause, a load or
///    a game that stopped presenting, and is left out, counted in ``Result/gaps``.
///
/// A window shorter than ``Rules/minimumSeconds`` carries no frame rate. `sevo perf` and the
/// run record read traces through the same function, so the two agree frame for frame.
nonisolated enum GameplayWindow {
    struct Rules: Equatable, Sendable {
        var warmup: Double = 10
        var steady: Double = 5
        var steadyFrame: Float = 100
        var settleLimit: Double = 120
        var gapFrame: Float = 250
        var focusGuard: Double = 2
        var minimumSeconds: Double = 30

        static let standard = Rules()
    }

    /// What the window kept of a trace.
    struct Result: Equatable, Sendable {
        /// Seconds after the trace's first frame that gameplay began.
        var from: Double
        /// The kept frames, in order.
        var frameTimes: [Float]
        /// Seconds after ``from`` left out as away.
        var away: Double
        /// Frames after ``from`` left out as gaps.
        var gaps: Int

        /// Seconds the kept frames cover.
        var seconds: Double {
            frameTimes.reduce(0.0) { $0 + Double($1) } / 1000
        }
    }

    /// The gameplay of a trace, or nil for one that never settled into play before it
    /// ended.
    static func compute(_ trace: FrameTrace.Contents, rules: Rules = .standard) -> Result? {
        let times = trace.frameTimes
        guard !times.isEmpty else { return nil }
        var ends: [Double] = []
        ends.reserveCapacity(times.count)
        var clock = 0.0
        for time in times {
            clock += Double(time) / 1000
            ends.append(clock)
        }
        let away = awayStretches(trace, guard: rules.focusGuard)
        let isAway = { (end: Double) in away.contains { $0.contains(end) } }
        guard let start = start(times, ends: ends, isAway: isAway, rules: rules) else { return nil }
        var kept: [Float] = []
        kept.reserveCapacity(times.count - start)
        var awaySeconds = 0.0
        var gaps = 0
        for index in start ..< times.count {
            if isAway(ends[index]) {
                awaySeconds += Double(times[index]) / 1000
            } else if times[index] > rules.gapFrame {
                gaps += 1
            } else {
                kept.append(times[index])
            }
        }
        return Result(
            from: ends[start] - Double(times[start]) / 1000, frameTimes: kept,
            away: awaySeconds, gaps: gaps,
        )
    }

    /// The record's summary of a trace's gameplay: nil when the trace has no gameplay at
    /// all, and no frame times for a window too short to carry a rate.
    static func gameplay(of trace: FrameTrace.Contents, rules: Rules = .standard) -> RunRecord.Gameplay? {
        guard let result = compute(trace, rules: rules) else { return nil }
        let seconds = result.seconds
        return RunRecord.Gameplay(
            from: round(result.from), seconds: round(seconds), away: round(result.away), gaps: result.gaps,
            frameTimes: seconds >= rules.minimumSeconds ? FrameStats.summarize(result.frameTimes) : nil,
        )
    }

    /// The first frame gameplay can start at (rule 1), or nil.
    private static func start(
        _ times: [Float], ends: [Double], isAway: (Double) -> Bool, rules: Rules,
    ) -> Int? {
        var index = 0
        while index < times.count {
            let begins = ends[index] - Double(times[index]) / 1000
            if begins < rules.warmup || isAway(ends[index]) || times[index] > rules.gapFrame {
                index += 1
                continue
            }
            if begins >= rules.settleLimit { return index }
            // The steady stretch: every frame ending within `steady` of this one's start.
            var probe = index
            var unsteady: Int?
            while probe < times.count, ends[probe] <= begins + rules.steady {
                if times[probe] > rules.steadyFrame || isAway(ends[probe]) {
                    unsteady = probe
                    break
                }
                probe += 1
            }
            if let unsteady {
                index = unsteady + 1
                continue
            }
            // A trace that ends inside the stretch never showed it steady.
            return probe < times.count ? index : nil
        }
        return nil
    }

    /// The stretches, in seconds of frames, that were away: from each change to a state
    /// other than focused, less the guard, to the next change back; and likewise for a
    /// virtual display.
    private static func awayStretches(
        _ trace: FrameTrace.Contents, guard margin: Double,
    ) -> [ClosedRange<Double>] {
        var changes: [(seconds: Double, away: Bool, kind: Int)] = []
        changes += trace.focus.map { ($0.seconds, $0.focus != .focused, 0) }
        changes += trace.displays.map { ($0.seconds, $0.display.virtual, 1) }
        changes.sort { $0.seconds < $1.seconds }
        var stretches: [ClosedRange<Double>] = []
        var awaySince: [Int: Double] = [:]
        func closeStretch(kind: Int, at seconds: Double) {
            guard let since = awaySince.removeValue(forKey: kind) else { return }
            stretches.append(max(0, since - margin) ... max(since, seconds))
        }
        for change in changes {
            if change.away {
                if awaySince[change.kind] == nil { awaySince[change.kind] = change.seconds }
            } else {
                closeStretch(kind: change.kind, at: change.seconds)
            }
        }
        for kind in Array(awaySince.keys) { closeStretch(kind: kind, at: .infinity) }
        return stretches
    }

    private static func round(_ value: Double) -> Double {
        (value * 10).rounded() / 10
    }
}
