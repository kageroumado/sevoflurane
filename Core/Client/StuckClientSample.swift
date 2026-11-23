import Foundation

/// What is kept of one episode in which the Steam client stopped answering,
/// written beside the app's log before the client is restarted: every
/// thread's stack of `steam.exe` and its web helpers, the end of Wine's log,
/// and the dumps Steam wrote meanwhile.
///
/// The restart follows within seconds and the next client start can rotate
/// Wine's log, so an episode's folder is the only record of the wait.
nonisolated enum StuckClientSample {
    /// Which probe found the client stuck.
    enum Probe: String, Sendable {
        /// `steam.exe` left the question only its main thread answers unanswered.
        case mainThread = "main-thread"
        /// Steam's DevTools port stopped answering.
        case devTools = "devtools"
    }

    // MARK: - Bounds

    /// How long each process is sampled.
    static let seconds = 3
    /// When a `sample` still running is ended, and the `gzip` of its report
    /// after it. The processes are sampled side by side, so a capture holds
    /// a restart back for the sampling and the writing of the largest report,
    /// and at the longest for these two and the subprocess runner's five
    /// seconds to reap each.
    static let sampleTimeout: Duration = .seconds(15)
    static let compressTimeout: Duration = .seconds(5)
    /// The most processes sampled in one episode.
    static let mostProcesses = 6
    /// How much of Wine's log an episode keeps.
    static let tailBytes = 1 << 20
    /// The most dumps an episode keeps, and the largest one it copies. The
    /// dumps Steam's watchdog writes are about 450 KB.
    static let mostDumps = 4
    static let largestDump = 4 << 20
    /// How long before the first unanswered probe a dump still belongs to the
    /// episode: Steam's watchdog writes one 15 s into a stall, and the probe
    /// that notices the stall can come a minute after it began.
    static let lead: TimeInterval = 120
    /// The most one episode keeps on disk. A sample of `steam.exe` is about
    /// 13 MB, most of it the indentation of frames the unwinder repeats, and
    /// 150 KB compressed, so an episode is about 3 MB; the bound leaves room
    /// for one sample `gzip` could not finish.
    static let episodeBytes = 32 << 20
    /// The most all episodes keep on disk together.
    static let totalBytes = 128 << 20

    // MARK: - Where it goes

    /// Where an episode's files come from and go to.
    struct Places: Sendable {
        /// The folder that holds one folder per episode.
        var root = StuckClientSample.root
        var wineLog = WineLog.fileURL
        /// Steam's own dumps (``SteamBottle/dumps``).
        var dumps = SteamBottle.dumps
    }

    /// `~/Library/Logs/Sevoflurane-stuck-steam`, beside the app's log.
    static var root: URL {
        AppIdentity.logFile(nil).deletingLastPathComponent().appending(path: "\(AppIdentity.logStem)-stuck-steam")
    }

    /// The folder of an episode captured at `date`; the stamp leads the name,
    /// so the folders sort oldest first.
    static func episodeFolder(_ probe: Probe, at date: Date = .now, in root: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HHmmss"
        return root.appending(path: "\(formatter.string(from: date))-\(probe.rawValue)")
    }

    // MARK: - Which processes

    /// One process to sample.
    struct Target: Equatable, Sendable {
        let pid: pid_t
        /// What the process is, which names its file: `steam`,
        /// `webhelper-browser`, `webhelper-renderer`.
        let label: String

        /// The report `sample` writes, `steam-57318.txt`; it is kept
        /// compressed, as `steam-57318.txt.gz`.
        var report: String {
            "\(label)-\(pid).txt"
        }
    }

    /// The label of a web helper with this command line. Chromium starts every
    /// process but the browser with `--type=`; the browser process is the one
    /// that serves the DevTools port. A helper whose command line cannot be
    /// read is a plain `webhelper`.
    static func helperLabel(commandLine: String?) -> String {
        guard let commandLine else { return "webhelper" }
        guard let type = commandLine.firstMatch(of: helperType)?.output.1 else { return "webhelper-browser" }
        return "webhelper-\(type)"
    }

    /// The processes to sample, most telling first: the client, the web
    /// helper's browser process, its GPU and utility processes, then the
    /// rest; ``mostProcesses`` at most.
    static func targets(client: [pid_t], helpers: [(pid: pid_t, commandLine: String?)]) -> [Target] {
        let helperTargets = helpers
            .filter { !client.contains($0.pid) }
            .map { Target(pid: $0.pid, label: helperLabel(commandLine: $0.commandLine)) }
            .sorted { (rank($0.label), $0.pid) < (rank($1.label), $1.pid) }
        return Array((client.sorted().map { Target(pid: $0, label: "steam") } + helperTargets).prefix(mostProcesses))
    }

    private static func rank(_ label: String) -> Int {
        ["webhelper-browser", "webhelper-gpu-process", "webhelper-utility"].firstIndex(of: label) ?? 3
    }

    private nonisolated(unsafe) static let helperType = #/--type=([a-z-]+)/#

    // MARK: - Capture

    /// What an episode's folder holds once its capture is done.
    struct Kept: Equatable, Sendable {
        var folder: URL
        /// The file names of the samples kept, in ``targets(client:helpers:)`` order.
        var samples: [String] = []
        /// Samples removed to keep the episode within ``episodeBytes``.
        var samplesDropped = 0
        /// How many bytes of Wine's log are kept, 0 when it could not be read.
        var wineTailBytes = 0
        /// The names of the dumps kept.
        var dumps: [String] = []
        /// The known faults Wine's log names since the client started.
        var faults: [StuckClientFault] = []
        /// Older episodes removed to keep all of them within ``totalBytes``.
        var episodesDropped = 0
    }

    /// Samples the bottle's `steam.exe` and its web helpers side by side, then
    /// keeps the Wine log's end and Steam's dumps beside the samples. Answers
    /// what was kept, or `nil` when there was no process to sample.
    ///
    /// - Parameter began: When the first probe of this episode went unanswered.
    static func capture(_ probe: Probe, began: Date, places: Places = Places()) async -> Kept? {
        let client = await ClientLifecycle.clientProcessIDs()
        let helpers = await ClientLifecycle.bottleProcessIDs(matching: "steamwebhelper.exe")
            .map { (pid: $0, commandLine: WineOrphans.commandLine(of: $0)) }
        let targets = targets(client: client, helpers: helpers)
        guard !targets.isEmpty else { return nil }
        let folder = episodeFolder(probe, in: places.root)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil else {
            return Kept(folder: folder)
        }
        let samples = await withTaskGroup(of: (pid: pid_t, file: String)?.self) { group in
            for target in targets {
                group.addTask { await sample(target, into: folder).map { (target.pid, $0) } }
            }
            var written: [pid_t: String] = [:]
            for await sample in group {
                if let sample { written[sample.pid] = sample.file }
            }
            return targets.compactMap { written[$0.pid] }
        }
        return keepEvidence(in: folder, samples: samples, began: began, places: places)
    }

    /// Samples one process into `folder` and compresses the report. Answers
    /// the name of the file kept, `nil` when `sample` wrote none.
    private static func sample(_ target: Target, into folder: URL) async -> String? {
        let report = folder.appending(path: target.report)
        let sampled = await Subprocess.run(
            "/usr/bin/sample", ["\(target.pid)", "\(seconds)", "-file", report.path],
            capture: .none, timeout: sampleTimeout,
        )
        guard sampled.status == 0 else { return nil }
        return await compress(report)
    }

    /// Compresses a report where it lies. Answers the name of the file kept:
    /// the compressed report, the plain one when `gzip` did not finish, `nil`
    /// when there is no report.
    static func compress(_ report: URL) async -> String? {
        guard FileManager.default.fileExists(atPath: report.path) else { return nil }
        let compressed = await Subprocess.run(
            "/usr/bin/gzip", ["-f", report.path], capture: .none, timeout: compressTimeout,
        )
        guard compressed.status == 0 else {
            // A `gzip` ended midway leaves its partial output beside the report.
            try? FileManager.default.removeItem(at: report.appendingPathExtension("gz"))
            return FileManager.default.fileExists(atPath: report.path) ? report.lastPathComponent : nil
        }
        return report.lastPathComponent + ".gz"
    }

    /// Puts the Wine log's end and the episode's dumps beside the samples
    /// already in `folder`, names the faults that end holds, and brings the
    /// episode within `limit` and then the whole root within ``totalBytes``.
    static func keepEvidence(
        in folder: URL, samples: [String], began: Date, places: Places, within limit: Int = episodeBytes,
    ) -> Kept {
        var kept = Kept(folder: folder, samples: samples)
        if let tail = wineTail(of: places.wineLog),
           (try? tail.write(to: folder.appending(path: wineTailName))) != nil {
            kept.wineTailBytes = tail.count
            kept.faults = StuckClientFault.faults(in: String(decoding: tail, as: UTF8.self))
        }
        for dump in dumps(in: places.dumps, writtenSince: began.addingTimeInterval(-lead)) {
            let copy = folder.appending(path: dump.lastPathComponent)
            guard (try? FileManager.default.copyItem(at: dump, to: copy)) != nil else { continue }
            kept.dumps.append(dump.lastPathComponent)
        }
        // The samples go first, the least telling process first: the log's
        // end and the dumps are small and say the most.
        var bytes = size(of: folder)
        while bytes > limit, let last = kept.samples.popLast() {
            let file = folder.appending(path: last)
            bytes -= size(of: file)
            try? FileManager.default.removeItem(at: file)
            kept.samplesDropped += 1
        }
        kept.episodesDropped = groom(places.root, keeping: folder)
        return kept
    }

    static let wineTailName = "wine-tail.log"

    /// The last ``tailBytes`` of Wine's log from the start of a line, or `nil`
    /// when the log cannot be read or is empty.
    static func wineTail(of log: URL, bytes: Int = tailBytes) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(bytes) ? size - UInt64(bytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A read that began inside the file began inside a line.
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) {
            data.removeSubrange(data.startIndex ... newline)
        }
        return data.isEmpty ? nil : data
    }

    /// Steam's `assert_steam.exe_*.dmp` files written at or after `since`,
    /// newest first: ``mostDumps`` at most, none larger than ``largestDump``.
    static func dumps(in directory: URL, writtenSince since: Date) -> [URL] {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: Array(keys),
        )) ?? []
        let recent: [(url: URL, written: Date)] = files.compactMap { file in
            let name = file.lastPathComponent.lowercased()
            guard name.hasPrefix("assert_steam.exe_"), name.hasSuffix(".dmp"),
                  let values = try? file.resourceValues(forKeys: keys),
                  let written = values.contentModificationDate, written >= since,
                  let size = values.fileSize, size <= largestDump else { return nil }
            return (file, written)
        }
        return recent.sorted { $0.written > $1.written }.prefix(mostDumps).map(\.url)
    }

    // MARK: - Disk

    /// Removes the oldest episodes under `root` until all of them together are
    /// within ``totalBytes``, never `current`. Answers how many went.
    @discardableResult
    static func groom(_ root: URL, keeping current: URL, within limit: Int = totalBytes) -> Int {
        let episodes = ((try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
        )) ?? [])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var sizes = episodes.map { size(of: $0) }
        var total = sizes.reduce(0, +)
        var dropped = 0
        for (index, episode) in episodes.enumerated() where total > limit {
            guard episode.lastPathComponent != current.lastPathComponent else { continue }
            guard (try? FileManager.default.removeItem(at: episode)) != nil else { continue }
            total -= sizes[index]
            sizes[index] = 0
            dropped += 1
        }
        return dropped
    }

    /// The bytes of a file, or of every file directly inside a folder.
    static func size(of url: URL) -> Int {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return ((try? manager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.intValue ?? 0
        }
        let files = (try? manager.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        return files.reduce(0) { total, file in
            total + (((try? manager.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0)
        }
    }

    // MARK: - What the event log says

    /// The event log's lines for an episode: what was kept and where, then
    /// each fault the Wine log names.
    static func lines(describing kept: Kept) -> [String] {
        var parts: [String] = []
        if !kept.samples.isEmpty {
            parts.append("samples " + kept.samples.joined(separator: ", "))
        }
        if kept.wineTailBytes > 0 {
            parts.append("the Wine log's last \((kept.wineTailBytes + 1023) / 1024) KB")
        }
        if !kept.dumps.isEmpty {
            parts.append("Steam's " + kept.dumps.joined(separator: ", "))
        }
        var lines = [
            parts.isEmpty
                ? "kept nothing of the stuck client: no sample, log or dump could be written to \(kept.folder.path)"
                : "kept of the stuck client in \(kept.folder.path): " + parts.joined(separator: "; "),
        ]
        if kept.samplesDropped > 0 {
            lines.append(
                "removed \(kept.samplesDropped) sample(s) to keep the episode within \(episodeBytes >> 20) MB",
            )
        }
        if kept.episodesDropped > 0 {
            lines.append(
                "removed the \(kept.episodesDropped) oldest episode(s) to keep all of them within \(totalBytes >> 20) MB",
            )
        }
        lines += kept.faults.map { "the Wine log since this client started names a known fault: \($0.sentence)" }
        return lines
    }
}
