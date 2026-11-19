import Foundation

/// The frames of a run that were gameplay: what a frame rate is measured over.
///
/// Loading screens, an unfocused window and a sleeping display all distort an
/// average, so the window is cut from a trace alone (``FrameTrace/Contents``):
///
/// 1. **Start.** The first frame at least ``Rules/warmup`` in from which ``Rules/steady``
///    seconds pass with no frame slower than ``Rules/steadyFrame``, or ``Rules/settleLimit``
///    for a run that never settles.
/// 2. **Away.** Frames while unfocused, hidden, asleep (``FrameTrace/Focus``) or on a
///    virtual display are left out, plus ``Rules/focusGuard`` seconds before each change,
///    since the app samples focus every two seconds.
/// 3. **Gaps.** Frames slower than ``Rules/gapFrame`` are left out and counted.
///
/// A window shorter than ``Rules/minimumSeconds`` carries no frame rate. `sevo perf` and the
/// run record share this function.
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

    struct Result: Equatable, Sendable {
        /// Seconds after the trace's first frame that gameplay began.
        var from: Double
        var frameTimes: [Float]
        /// Seconds after ``from`` left out as away.
        var away: Double
        var gaps: Int

        var seconds: Double {
            frameTimes.reduce(0.0) { $0 + Double($1) } / 1000
        }
    }

    /// The gameplay of a trace, or nil for one that never settled.
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

    /// The record's gameplay summary; no frame times for a window too short.
    static func gameplay(of trace: FrameTrace.Contents, rules: Rules = .standard) -> RunRecord.Gameplay? {
        guard let result = compute(trace, rules: rules) else { return nil }
        let seconds = result.seconds
        let measured = seconds >= rules.minimumSeconds
        return RunRecord.Gameplay(
            from: round(result.from), seconds: round(seconds), away: round(result.away), gaps: result.gaps,
            frameTimes: measured ? FrameStats.summarize(result.frameTimes) : nil,
            steadyFPS: measured ? steadyRate(result.frameTimes) : nil,
        )
    }

    /// How far the 5th and 95th percentiles may lie from the median for a steady rate.
    static let steadyBand = 1.1

    /// The rate a capped or display-paced run was held to, or nil for frames that
    /// wandered; the community database takes the highest as the game's own cap.
    static func steadyRate(_ times: [Float]) -> Double? {
        guard times.count >= 100 else { return nil }
        let sorted = times.sorted()
        let p5 = FrameStats.percentile(sorted, 0.05)
        let p50 = FrameStats.percentile(sorted, 0.50)
        let p95 = FrameStats.percentile(sorted, 0.95)
        guard p50 > 0, p95 <= p50 * steadyBand, p5 >= p50 / steadyBand else { return nil }
        return round(1000 / p50)
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

    /// The away stretches in seconds, each starting `margin` early.
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
