import Foundation

/// Every frame of a run, one line each, beside the run records.
///
/// `Runs/traces/<run>.csv`, where `<run>` is the record's start and app id
/// (``name(for:)``). The file is plain CSV so any tool can read it: two comment lines
/// naming the run, a header, then `time_s,frame_ms` per frame, where `time_s` is when the
/// frame ended counted from the run's first frame. The present counter's ring is where the
/// times come from (``PresentStats``); a gap the ring could not cover is a line of its own,
/// `# dropped <n>`, so a reader knows the time axis skips there.
nonisolated enum FrameTrace {
    static let directoryName = "traces"

    static func directory(in runs: URL = RunLog.root) -> URL {
        runs.appendingPathComponent(directoryName)
    }

    /// The trace's file name for a run that began at `stamp` (a record's `t`).
    static func name(appID: Int, stamp: String) -> String {
        let safe = stamp.replacingOccurrences(of: ":", with: "-")
        return "\(safe)-\(appID).csv"
    }

    static func url(appID: Int, stamp: String, in runs: URL = RunLog.root) -> URL {
        directory(in: runs).appendingPathComponent(name(appID: appID, stamp: stamp))
    }

    // MARK: - Writing

    /// Appends a run's frames as they arrive. Not thread-safe; ``PresentStats`` calls it
    /// under its lock.
    final class Writer {
        let url: URL
        private var handle: FileHandle?
        private var pending = ""
        private var clock: Double = 0

        init?(url: URL, appID: Int, stamp: String) {
            self.url = url
            let directory = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let header = "# sevoflurane frame trace 1\n# appid=\(appID) t=\(stamp)\ntime_s,frame_ms\n"
            guard FileManager.default.createFile(atPath: url.path, contents: Data(header.utf8)),
                  let handle = try? FileHandle(forWritingTo: url) else { return nil }
            _ = try? handle.seekToEnd()
            self.handle = handle
        }

        func append(_ frameTimes: some Sequence<Float>) {
            for time in frameTimes {
                clock += Double(time) / 1000
                pending += String(format: "%.4f,%.3f\n", clock, time)
            }
            flushIfLarge()
        }

        func noteDropped(_ count: Int) {
            guard count > 0 else { return }
            pending += "# dropped \(count)\n"
        }

        func close() {
            flush()
            try? handle?.close()
            handle = nil
        }

        private func flushIfLarge() {
            if pending.utf8.count > 64 * 1024 { flush() }
        }

        func flush() {
            guard !pending.isEmpty, let handle else { return }
            try? handle.write(contentsOf: Data(pending.utf8))
            pending = ""
        }

        deinit { close() }
    }

    // MARK: - Keeping

    /// How many traces are kept and how much disk they may take together; the oldest go
    /// first. A trace is about 20 bytes a frame, so an hour at 60 fps is 4 MB.
    static let keptCount = 300
    static let keptBytes: Int64 = 1_000_000_000

    /// Removes the oldest traces past either limit.
    static func groom(in runs: URL = RunLog.root) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory(in: runs), includingPropertiesForKeys: keys,
        ) else { return }
        let traces = files.filter { $0.pathExtension == "csv" }.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return (url, values?.contentModificationDate ?? .distantPast, Int64(values?.fileSize ?? 0))
        }.sorted { $0.1 > $1.1 }
        var total: Int64 = 0
        for (index, trace) in traces.enumerated() {
            total += trace.2
            if index >= keptCount || total > keptBytes { try? FileManager.default.removeItem(at: trace.0) }
        }
    }

    // MARK: - Reading

    /// A trace read back: the frame times in order and the frames the ring lost.
    struct Contents: Equatable, Sendable {
        var frameTimes: [Float]
        var dropped: Int
    }

    static func read(_ url: URL) -> Contents? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var times: [Float] = []
        var dropped = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            if line.hasPrefix("# dropped ") {
                dropped += Int(line.dropFirst("# dropped ".count)) ?? 0
                continue
            }
            guard let comma = line.firstIndex(of: ","), !line.hasPrefix("#"),
                  let time = Float(line[line.index(after: comma)...]) else { continue }
            times.append(time)
        }
        return Contents(frameTimes: times, dropped: dropped)
    }
}
