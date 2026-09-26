import Foundation

/// Runs with frame traces, grouped by what they ran on, and each group measured against the
/// first.
///
/// A group is every run whose configuration is the same: engine, renderer, upscaler, tuning,
/// msync, D3DMetal, window treatment, and the label a person gave the run
/// (``PerfLabels``). Repeating a configuration is what makes its difference from another
/// one testable; ``FrameStats`` says how.
nonisolated enum PerfComparison {
    /// One run as the comparison sees it: its record and its frames.
    struct Run: Sendable {
        var record: RunRecord
        var frameTimes: [Float]
        var dropped: Int
        /// The trace's file name, which is also the run's key for a label.
        var trace: String
        var label: String?
        /// How long the whole trace runs, in seconds, and the stretch of it
        /// ``frameTimes`` covers after trimming (``trim(_:skip:duration:)``).
        var traceSeconds: Double?
        var window: ClosedRange<Double>?

        var summary: FrameStats.Summary? {
            FrameStats.summarize(frameTimes)
        }
    }

    /// The settings that decide a run's configuration, in the order a label names them.
    static func configuration(of run: Run) -> [(field: String, value: String)] {
        let record = run.record
        return [
            ("engine", record.engine),
            ("renderer", record.renderer),
            ("upscaler", record.upscaler ?? "off"),
            ("tuning", record.tuning ?? "standard"),
            ("msync", record.msync ? "on" : "off"),
            ("d3dmetal", record.d3dmetal ?? "–"),
            ("windows", record.windows),
            ("label", run.label ?? ""),
        ]
    }

    struct Group: Sendable {
        /// What sets this group apart from the others, e.g. `dormison-r16 · upscaler metalfx`.
        var name: String
        var runs: [Run]
    }

    /// The runs grouped by configuration, in the order each configuration first appears.
    static func groups(_ runs: [Run]) -> [Group] {
        var order: [String] = []
        var members: [String: [Run]] = [:]
        for run in runs {
            let key = configuration(of: run).map { "\($0.field)=\($0.value)" }.joined(separator: ";")
            if members[key] == nil { order.append(key) }
            members[key, default: []].append(run)
        }
        let grouped = order.compactMap { members[$0] }
        let differing = differingFields(grouped.compactMap(\.first))
        return grouped.map { runs in
            Group(name: name(of: runs[0], showing: differing), runs: runs)
        }
    }

    /// The configuration fields whose value is not the same in every run given.
    static func differingFields(_ runs: [Run]) -> [String] {
        guard let first = runs.first else { return [] }
        return configuration(of: first).map(\.field).filter { field in
            Set(runs.map { run in configuration(of: run).first { $0.field == field }?.value ?? "" }).count > 1
        }
    }

    /// A run's name among others: its label when it has one, then the fields that differ.
    static func name(of run: Run, showing fields: [String]) -> String {
        let values = configuration(of: run)
        var parts: [String] = []
        if let label = run.label, !label.isEmpty { parts.append(label) }
        for field in fields where field != "label" {
            guard let value = values.first(where: { $0.field == field })?.value else { continue }
            parts.append(field == "engine" || field == "renderer" ? value : "\(field) \(value)")
        }
        return parts.isEmpty ? run.record.engine : parts.joined(separator: " · ")
    }

    /// How a group differs from the baseline in average frame rate and in 1 % low.
    struct Versus: Sendable {
        var average: FrameStats.Difference?
        var low1: FrameStats.Difference?
    }

    /// `group` against `baseline`: Welch's test over run-level values when both sides have
    /// at least two runs, otherwise a block bootstrap over the pooled frames of each side.
    static func versus(_ group: Group, baseline: Group) -> Versus {
        if group.runs.count >= 2, baseline.runs.count >= 2 {
            let base = baseline.runs.compactMap(\.summary), other = group.runs.compactMap(\.summary)
            return Versus(
                average: FrameStats.welch(base.map(\.avg), other.map(\.avg)),
                low1: FrameStats.welch(base.map(\.low1), other.map(\.low1)),
            )
        }
        let base = baseline.runs.flatMap(\.frameTimes), other = group.runs.flatMap(\.frameTimes)
        return Versus(
            average: FrameStats.blockBootstrap(base, other, statistic: FrameStats.averageRate),
            low1: FrameStats.blockBootstrap(base, other, statistic: FrameStats.lowRate1),
        )
    }

    /// The seconds to leave out of the run at `position` among the chosen ones:
    /// its own value in `skips`, the last value for every run past the list,
    /// and none when the list is empty.
    static func skip(_ skips: [Double], forRun position: Int) -> Double {
        guard let last = skips.last else { return 0 }
        return skips.indices.contains(position) ? skips[position] : last
    }

    /// `240,85` as seconds per run; nil for a list with anything but
    /// non-negative numbers in it.
    static func skips(parsing text: String) -> [Double]? {
        let values = text.split(separator: ",", omittingEmptySubsequences: false)
            .map { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard !values.isEmpty, values.allSatisfy({ ($0 ?? -1) >= 0 }) else { return nil }
        return values.compactMap(\.self)
    }

    /// Frames from `skip` seconds after the first, for `duration` seconds when given.
    static func trim(_ times: [Float], skip: Double, duration: Double?) -> [Float] {
        var elapsed = 0.0
        var kept: [Float] = []
        // A microsecond of slack, so a frame ending on the boundary is on its near side.
        let slack = 1e-6
        for time in times {
            elapsed += Double(time) / 1000
            if elapsed <= skip + slack { continue }
            if let duration, elapsed > skip + duration + slack { break }
            kept.append(time)
        }
        return kept
    }
}

/// Names a person gives runs, kept beside the traces in `labels.json` (trace file name →
/// label), so a comparison of two settings the record cannot tell apart still reads right.
nonisolated enum PerfLabels {
    static func url(in runs: URL = RunLog.root) -> URL {
        FrameTrace.directory(in: runs).appendingPathComponent("labels.json")
    }

    static func all(in runs: URL = RunLog.root) -> [String: String] {
        guard let data = try? Data(contentsOf: url(in: runs)),
              let labels = try? JSONDecoder().decode([String: String].self, from: data) else { return [:] }
        return labels
    }

    static func set(_ label: String?, forTrace trace: String, in runs: URL = RunLog.root) throws {
        var labels = all(in: runs)
        labels[trace] = label?.isEmpty == false ? label : nil
        try FileManager.default.createDirectory(
            at: FrameTrace.directory(in: runs), withIntermediateDirectories: true,
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(labels).write(to: url(in: runs), options: .atomic)
    }
}
