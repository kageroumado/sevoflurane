import Foundation

/// The run records on disk: one JSON Lines file per month under `~/Library/Application
/// Support/Sevoflurane/Runs`, past months compressed, twelve kept, and `open/` holding armed runs
/// not yet recorded. JSON Lines because the appending process may be killed mid-write, and a
/// truncated line then costs one record. Every entry point takes the directory, so tests write
/// elsewhere.
nonisolated enum RunLog {
    /// `SEVO_RUNS_DIR` moves the directory, for a harness keeping its runs apart or `sevo perf`
    /// reading a copy.
    static let root = ProcessInfo.processInfo.environment["SEVO_RUNS_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? AppIdentity.supportFolder
        .appendingPathComponent("Runs")

    static func hasRecords(in root: URL = root) -> Bool {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.contains { $0.hasSuffix(".jsonl") }
    }

    /// Whether a run of `appID` was ever recorded here, in any month kept.
    static func hasRecord(forApp appID: Int, in root: URL = root) -> Bool {
        monthFiles(in: root).reversed().contains { url in
            lines(in: url).contains { (try? decoder.decode(AppOnly.self, from: Data($0)))?.appid == appID }
        }
    }

    private struct AppOnly: Decodable {
        let appid: Int
    }

    static let monthsKept = 12

    /// How long a stop request stands for the next run that ends.
    static let stopRequestLife: TimeInterval = 60

    private static func stopRequestURL(forApp appID: Int, in root: URL) -> URL {
        root.appendingPathComponent(".stop-\(appID)")
    }

    /// Who asked for a game to stop.
    enum StopSource: String, Sendable {
        /// A person: Steam's Stop button, Sevoflurane's menu or popover, all through the page's
        /// `TerminateApp`.
        case player
        /// `sevo` or an agent using it, stopping whenever a script is done.
        case tool
    }

    /// Leaves word that this app is being stopped on purpose, and by whom, for the recorder; a
    /// file, because `sevo` and the app are different processes.
    static func noteStopRequest(forApp appID: Int, by source: StopSource, in root: URL = root) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data(source.rawValue.utf8).write(to: stopRequestURL(forApp: appID, in: root))
    }

    /// Who asked for a stop within ``stopRequestLife``, or nil; the word is consumed, so it answers
    /// one ending.
    static func takeStopRequest(forApp appID: Int, in root: URL = root) -> StopSource? {
        let url = stopRequestURL(forApp: appID, in: root)
        guard let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
              let contents = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        try? FileManager.default.removeItem(at: url)
        guard Date().timeIntervalSince(written) <= stopRequestLife else { return nil }
        return StopSource(rawValue: contents)
    }

    static func url(forMonth date: Date, in root: URL = root) -> URL {
        root.appendingPathComponent("\(month(of: date)).jsonl")
    }

    /// Appends one record through one queue, since a seek-to-end and write is not atomic against
    /// another append.
    static func append(_ record: RunRecord, in root: URL = root) {
        guard let line = try? encoder.encode(record) else { return }
        writes.sync {
            let manager = FileManager.default
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            let url = url(forMonth: .now, in: root)
            if !manager.fileExists(atPath: url.path) {
                manager.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line + Data("\n".utf8))
        }
    }

    private static let writes = DispatchQueue(label: "sevo.runlog")

    // MARK: - Runs that are still open

    /// A launch armed and not yet closed, on disk so a game left running by a force-quit is
    /// recorded at the app's next launch. One file per app id, removed when recorded.
    struct ArmedRun: Codable, Sendable {
        var record: RunRecord
        /// When the run was armed, wall clock, since a run that outlived the app cannot be timed on
        /// a monotonic clock.
        var started: Date
        var wineLogOffset: UInt64
        var steamLogOffset: UInt64
        var steamError: String?
        /// Steam's process log for the booted engine, so a reattached run reads its exit from the
        /// bottle it armed against. Absent in older files.
        var steamLog: String?
    }

    /// Where armed runs are parked, one file per app id so one arming never rewrites another.
    static func openRoot(in root: URL = root) -> URL {
        root.appendingPathComponent("open")
    }

    static func arm(_ run: ArmedRun, in root: URL = root) {
        guard let data = try? encoder.encode(run) else { return }
        writes.sync {
            try? FileManager.default
                .createDirectory(at: openRoot(in: root), withIntermediateDirectories: true)
            try? data.write(to: openURL(forApp: run.record.appid, in: root), options: .atomic)
        }
    }

    /// Forgets an armed run.
    static func disarm(appID: Int, in root: URL = root) {
        writes.sync {
            try? FileManager.default.removeItem(at: openURL(forApp: appID, in: root))
        }
    }

    /// Every run left armed, in file-name order.
    static func armedRuns(in root: URL = root) -> [ArmedRun] {
        let open = openRoot(in: root)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: open.path)) ?? []
        return names.sorted().compactMap { name in
            guard name.hasSuffix(".json"),
                  let data = try? Data(contentsOf: open.appendingPathComponent(name))
            else { return nil }
            return try? decoder.decode(ArmedRun.self, from: data)
        }
    }

    private static func openURL(forApp appID: Int, in root: URL) -> URL {
        openRoot(in: root).appendingPathComponent("\(appID).json")
    }

    static func records(inMonth date: Date, in root: URL = root) -> [RunRecord] {
        records(in: url(forMonth: date, in: root))
    }

    /// The most recent records, oldest first by launch start rather than append order: a game still
    /// up at quit is written after later games.
    static func recent(_ limit: Int, in root: URL = root) -> [RunRecord] {
        var found: [RunRecord] = []
        for url in monthFiles(in: root).reversed() {
            found = records(in: url) + found
            if found.count >= limit { break }
        }
        return Array(found.sorted { $0.t < $1.t }.suffix(limit))
    }

    /// Compresses every month before this one and drops all but the newest ``monthsKept``; cheap to
    /// run at each app start.
    static func groom(in root: URL = root) {
        let manager = FileManager.default
        let current = month(of: .now)
        for url in monthFiles(in: root) where url.pathExtension == "jsonl" {
            guard url.deletingPathExtension().lastPathComponent != current,
                  let data = try? Data(contentsOf: url),
                  let compressed = try? (data as NSData).compressed(using: .zlib) else { continue }
            let target = url.appendingPathExtension(compressedExtension)
            guard (try? compressed.write(to: target)) != nil else { continue }
            try? manager.removeItem(at: url)
        }
        let files = monthFiles(in: root)
        guard files.count > monthsKept else { return }
        for url in files.prefix(files.count - monthsKept) {
            try? manager.removeItem(at: url)
        }
    }

    /// A month's records; `url` may name the `.jsonl` or its `.jsonl.z`.
    private static func records(in url: URL) -> [RunRecord] {
        lines(in: url).compactMap { try? decoder.decode(RunRecord.self, from: Data($0)) }
    }

    private static func lines(in url: URL) -> [Data.SubSequence] {
        let manager = FileManager.default
        let data: Data? = if url.pathExtension == compressedExtension {
            decompressed(at: url)
        } else if manager.fileExists(atPath: url.path) {
            try? Data(contentsOf: url)
        } else {
            decompressed(at: url.appendingPathExtension(compressedExtension))
        }
        guard let data else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
    }

    private static func decompressed(at url: URL) -> Data? {
        (try? Data(contentsOf: url)).flatMap { try? ($0 as NSData).decompressed(using: .zlib) as Data }
    }

    /// Every month's file, oldest first; the names sort chronologically.
    private static func monthFiles(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.\(compressedExtension)") }
            .sorted()
            .map { root.appendingPathComponent($0) }
    }

    /// Raw zlib, which `NSData` handles without a subprocess.
    private static let compressedExtension = "z"

    private static func month(of date: Date) -> String {
        monthStamp.string(from: date)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// Month names use local time, the reader's month boundary.
    private static let monthStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
