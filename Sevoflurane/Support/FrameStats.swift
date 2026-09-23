import Foundation

/// What a run's frame times say, and whether two sets of runs differ.
///
/// The unit of a frame-time statistic is the frame; the unit of a comparison is the run.
/// Frames of one run are not independent — a scene that is slow for a second is slow for
/// sixty frames — so a test that counts frames as samples calls every difference
/// significant. Runs repeated under one configuration are independent, and they are what
/// ``PerfComparison/versus(_:baseline:)`` tests. With a single run on a side, the comparison falls back to a
/// moving-block bootstrap over that run's seconds, which keeps the within-second
/// correlation and is labeled as the weaker evidence it is.
nonisolated enum FrameStats {
    /// The summary of one run's frames.
    struct Summary: Codable, Equatable, Sendable {
        var frames: Int
        /// Seconds the frames cover.
        var seconds: Double
        /// Frames per second over the whole span.
        var avg: Double
        /// The frame rate of the slowest one per cent of frames, averaged: 1000 / the mean of
        /// the slowest 1 % of frame times.
        var low1: Double
        var low01: Double
        /// Frame-time percentiles, milliseconds.
        var p50: Double
        var p95: Double
        var p99: Double
        var p999: Double
        var max: Double
        /// Standard deviation of the frame times, milliseconds.
        var stdev: Double
        /// Frames that took more than twice as long as the median of the frames around them
        /// and at least 8 ms longer: what a player sees as a hitch.
        var hitches: Int

        enum CodingKeys: String, CodingKey {
            case frames, seconds, avg, low1, low01, p50, p95, p99, p999, max, stdev, hitches
        }
    }

    // MARK: - One run

    /// The summary of `times` (milliseconds), or nil for fewer than two frames.
    static func summarize(_ times: [Float]) -> Summary? {
        guard times.count >= 2 else { return nil }
        let sorted = times.sorted()
        let total = times.reduce(0.0) { $0 + Double($1) }
        guard total > 0 else { return nil }
        let mean = total / Double(times.count)
        let variance = times.reduce(0.0) { $0 + (Double($1) - mean) * (Double($1) - mean) } / Double(times.count)
        return Summary(
            frames: times.count,
            seconds: round(total / 1000, 2),
            avg: round(Double(times.count) / (total / 1000), 1),
            low1: round(lowRate(sorted, fraction: 0.01), 1),
            low01: round(lowRate(sorted, fraction: 0.001), 1),
            p50: round(percentile(sorted, 0.50), 2),
            p95: round(percentile(sorted, 0.95), 2),
            p99: round(percentile(sorted, 0.99), 2),
            p999: round(percentile(sorted, 0.999), 2),
            max: round(Double(sorted.last ?? 0), 2),
            stdev: round(variance.squareRoot(), 2),
            hitches: hitchCount(times),
        )
    }

    /// The frame rate of the slowest `fraction` of frames, averaged over them.
    static func lowRate(_ sorted: [Float], fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let count = Swift.max(1, Int((Double(sorted.count) * fraction).rounded(.down)))
        let slowest = sorted.suffix(count).reduce(0.0) { $0 + Double($1) }
        return slowest > 0 ? 1000 * Double(count) / slowest : 0
    }

    /// Nearest-rank percentile of an ascending array.
    static func percentile(_ sorted: [Float], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let rank = Int((p * Double(sorted.count)).rounded(.up)) - 1
        return Double(sorted[Swift.min(sorted.count - 1, Swift.max(0, rank))])
    }

    /// How many frames of the neighborhood around them are the median; the count is
    /// odd so the median is a frame.
    static let hitchWindow = 31

    static func hitchCount(_ times: [Float]) -> Int {
        guard times.count >= hitchWindow else { return 0 }
        let half = hitchWindow / 2
        var count = 0
        var window = Array(times[0 ..< hitchWindow]).sorted()
        for index in half ..< times.count - half {
            if index > half {
                // Slide: drop the frame leaving the window, insert the one entering it.
                let leaving = times[index - half - 1], entering = times[index + half]
                if let at = window.firstIndex(of: leaving) { window.remove(at: at) }
                window.insert(entering, at: window.firstIndex { $0 >= entering } ?? window.count)
            }
            let median = window[half], frame = times[index]
            if frame > 2 * median, frame - median >= 8 { count += 1 }
        }
        return count
    }

    /// Frames per second in each whole second of the run, from its frame times.
    static func perSecond(_ times: [Float]) -> [Double] {
        var rates: [Double] = []
        var elapsed: Double = 0, frames = 0
        for time in times {
            elapsed += Double(time) / 1000
            frames += 1
            if elapsed >= 1 {
                rates.append(Double(frames) / elapsed)
                elapsed = 0
                frames = 0
            }
        }
        return rates
    }

    // MARK: - Comparing

    /// How a statistic moved from `a` to `b`, with an interval and a verdict.
    struct Difference: Codable, Equatable, Sendable {
        /// The statistic on the baseline side, a.
        var base: Double
        /// b − a, in the statistic's unit.
        var delta: Double
        /// delta / a, as a percentage.
        var percent: Double
        /// 95 % confidence interval of `delta`.
        var low: Double
        var high: Double
        /// Two-sided p value, when the method gives one.
        var p: Double?
        var method: Method

        enum Method: String, Codable, Sendable {
            /// Welch's t-test over the runs of each side.
            case welch
            /// A moving-block bootstrap over one run's seconds on each side.
            case blockBootstrap = "block-bootstrap"
        }

        /// The interval's ends as percentages of the baseline.
        var percentLow: Double { base != 0 ? 100 * low / base : 0 }
        var percentHigh: Double { base != 0 ? 100 * high / base : 0 }

        /// The interval excludes zero.
        var isSignificant: Bool {
            low > 0 || high < 0
        }
    }

    /// Welch's t-test and interval for the difference of means, `b − a`. Nil with fewer than
    /// two values on a side or no variance at all.
    static func welch(_ a: [Double], _ b: [Double]) -> Difference? {
        guard a.count >= 2, b.count >= 2 else { return nil }
        let (ma, va) = meanAndVariance(a), (mb, vb) = meanAndVariance(b)
        let sa = va / Double(a.count), sb = vb / Double(b.count)
        let standardError = (sa + sb).squareRoot()
        let delta = mb - ma
        guard standardError > 0 else {
            return Difference(
                base: ma, delta: delta, percent: ma != 0 ? 100 * delta / ma : 0, low: delta, high: delta,
                p: delta == 0 ? 1 : 0, method: .welch,
            )
        }
        let df = (sa + sb) * (sa + sb)
            / (sa * sa / Double(a.count - 1) + sb * sb / Double(b.count - 1))
        let t = delta / standardError
        let critical = studentTQuantile(0.975, df: df)
        return Difference(
            base: ma, delta: delta, percent: ma != 0 ? 100 * delta / ma : 0,
            low: delta - critical * standardError, high: delta + critical * standardError,
            p: 2 * (1 - studentTCDF(abs(t), df: df)), method: .welch,
        )
    }

    /// The difference of `statistic` between two runs' frames, `b − a`, with a 95 % interval
    /// from a moving-block bootstrap: each resample strings together whole seconds of the run
    /// in blocks of `blockSeconds`, so the correlation inside a scene stays in the sample.
    static func blockBootstrap(
        _ a: [Float], _ b: [Float], blockSeconds: Int = 5, resamples: Int = 1000, seed: UInt64 = 1,
        statistic: ([Float]) -> Double,
    ) -> Difference? {
        let secondsA = secondsOf(a), secondsB = secondsOf(b)
        guard secondsA.count >= 2 * blockSeconds, secondsB.count >= 2 * blockSeconds else { return nil }
        var generator = SplitMix(seed: seed)
        let observed = statistic(b) - statistic(a)
        var deltas: [Double] = []
        deltas.reserveCapacity(resamples)
        for _ in 0 ..< resamples {
            let ra = resample(secondsA, block: blockSeconds, using: &generator)
            let rb = resample(secondsB, block: blockSeconds, using: &generator)
            deltas.append(statistic(rb) - statistic(ra))
        }
        deltas.sort()
        let base = statistic(a)
        return Difference(
            base: base, delta: observed, percent: base != 0 ? 100 * observed / base : 0,
            low: deltas[Int(0.025 * Double(resamples))], high: deltas[Int(0.975 * Double(resamples)) - 1],
            p: nil, method: .blockBootstrap,
        )
    }

    /// Average frame rate of a set of frame times.
    static func averageRate(_ times: [Float]) -> Double {
        let total = times.reduce(0.0) { $0 + Double($1) }
        return total > 0 ? Double(times.count) / (total / 1000) : 0
    }

    /// The 1 % low of a set of frame times.
    static func lowRate1(_ times: [Float]) -> Double {
        lowRate(times.sorted(), fraction: 0.01)
    }

    // MARK: - Helpers

    private static func secondsOf(_ times: [Float]) -> [ArraySlice<Float>] {
        var seconds: [ArraySlice<Float>] = []
        var start = 0, elapsed: Float = 0
        for (index, time) in times.enumerated() {
            elapsed += time
            if elapsed >= 1000 {
                seconds.append(times[start ... index])
                start = index + 1
                elapsed = 0
            }
        }
        return seconds
    }

    private static func resample(
        _ seconds: [ArraySlice<Float>], block: Int, using generator: inout SplitMix,
    ) -> [Float] {
        var out: [Float] = []
        let starts = seconds.count - block + 1
        while out.count < seconds.reduce(0, { $0 + $1.count }) {
            let start = Int(generator.next() % UInt64(starts))
            for second in seconds[start ..< start + block] { out.append(contentsOf: second) }
        }
        return out
    }

    private static func meanAndVariance(_ values: [Double]) -> (Double, Double) {
        let mean = values.reduce(0, +) / Double(values.count)
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count - 1)
        return (mean, variance)
    }

    private static func round(_ value: Double, _ places: Int) -> Double {
        let scale = pow(10, Double(places))
        return (value * scale).rounded() / scale
    }

    // MARK: - Student's t

    /// The t distribution's CDF, through the regularized incomplete beta function.
    static func studentTCDF(_ t: Double, df: Double) -> Double {
        let x = df / (df + t * t)
        let tail = 0.5 * incompleteBeta(x, a: df / 2, b: 0.5)
        return t >= 0 ? 1 - tail : tail
    }

    /// The t quantile, by bisection of the CDF.
    static func studentTQuantile(_ p: Double, df: Double) -> Double {
        var low = -1000.0, high = 1000.0
        for _ in 0 ..< 200 {
            let mid = (low + high) / 2
            if studentTCDF(mid, df: df) < p { low = mid } else { high = mid }
        }
        return (low + high) / 2
    }

    /// I_x(a, b), by Lentz's continued fraction (Numerical Recipes' `betacf`).
    static func incompleteBeta(_ x: Double, a: Double, b: Double) -> Double {
        guard x > 0 else { return 0 }
        guard x < 1 else { return 1 }
        let front = exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * log(x) + b * log(1 - x))
        if x < (a + 1) / (a + b + 2) { return front * continuedFraction(x, a: a, b: b) / a }
        return 1 - front * continuedFraction(1 - x, a: b, b: a) / b
    }

    private static func continuedFraction(_ x: Double, a: Double, b: Double) -> Double {
        let tiny = 1e-300
        var c = 1.0, d = 1 - (a + b) * x / (a + 1)
        if abs(d) < tiny { d = tiny }
        d = 1 / d
        var result = d
        for m in 1 ... 300 {
            let m = Double(m), m2 = 2 * m
            var aa = m * (b - m) * x / ((a + m2 - 1) * (a + m2))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            result *= d * c
            aa = -(a + m) * (a + b + m) * x / ((a + m2) * (a + m2 + 1))
            d = 1 + aa * d; if abs(d) < tiny { d = tiny }
            c = 1 + aa / c; if abs(c) < tiny { c = tiny }
            d = 1 / d
            let step = d * c
            result *= step
            if abs(step - 1) < 1e-12 { break }
        }
        return result
    }
}

/// A small seeded generator, so a report's intervals are the same every time it is drawn.
nonisolated struct SplitMix: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
