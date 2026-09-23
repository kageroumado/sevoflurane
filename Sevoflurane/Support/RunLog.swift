import Foundation

/// The run records on disk: one JSON Lines file per month under
/// `~/Library/Application Support/Sevoflurane/Runs`, months before the current
/// one compressed, twelve kept, and `open/` beside them holding the launches
/// that have been armed and not yet recorded.
///
/// JSON Lines rather than one document: a record is appended by a process
/// that may be killed at any moment, and a truncated last line costs one
/// record instead of the file.
///
/// Every entry point takes the directory to work in, defaulting to the one
/// the app and the CLI share, so a test can drive a whole recorder without
/// writing into it.
nonisolated enum RunLog {
    /// `SEVO_RUNS_DIR` points a process somewhere else: a harness keeping its runs apart
    /// from the ones played on the Mac, or `sevo perf` reading a copy.
    static let root = ProcessInfo.processInfo.environment["SEVO_RUNS_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Runs")

    /// How many months are kept.
    static let monthsKept = 12

    /// How long a stop request stands for the run that ends after it.
    static let stopRequestLife: TimeInterval = 60

    private static func stopRequestURL(forApp appID: Int, in root: URL) -> URL {
        root.appendingPathComponent(".stop-\(appID)")
    }

    /// Leaves word that this app is about to be stopped on purpose, for the
    /// recorder that will see its process exit with status 1. A file, because
    /// the request can come from `sevo` and the recorder lives in the app.
    static func noteStopRequest(forApp appID: Int, in root: URL = root) {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try? Data().write(to: stopRequestURL(forApp: appID, in: root))
    }

    /// Whether a stop was asked for within ``stopRequestLife``; the word is
    /// taken, so it answers for one ending.
    static func takeStopRequest(forApp appID: Int, in root: URL = root) -> Bool {
        let url = stopRequestURL(forApp: appID, in: root)
        guard let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
        else { return false }
        try? FileManager.default.removeItem(at: url)
        return Date().timeIntervalSince(written) <= stopRequestLife
    }

    /// A month's file, whether or not it exists.
    static func url(forMonth date: Date, in root: URL = root) -> URL {
        root.appendingPathComponent("\(month(of: date)).jsonl")
    }

    /// Appends one record. Two games can end at the same moment, and a
    /// seek-to-end followed by a write is not atomic against another one, so
    /// every append goes through one queue.
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

    /// A launch that has been armed and not yet closed, as it sits on disk.
    ///
    /// The in-memory recorder dies with its process, and a game does not: a
    /// force-quit under a running game would otherwise leave nothing for the
    /// next launch of the app to write. One file per app id, removed when the
    /// run is recorded.
    struct ArmedRun: Codable, Sendable {
        var record: RunRecord
        /// When the run was armed, wall clock — the elapsed time of a run
        /// that outlived the app cannot come off a monotonic clock.
        var started: Date
        var wineLogOffset: UInt64
        var steamLogOffset: UInt64
        /// The client's error for this game action, when it showed one.
        var steamError: String?
        /// Steam's process log for the engine that booted the client, so a
        /// reattached run reads its exit from the same bottle it armed
        /// against. Absent for a run armed before this was recorded.
        var steamLog: String?
    }

    /// Where armed runs are parked. A directory rather than a file, so one
    /// game's arming never rewrites another's.
    static func openRoot(in root: URL = root) -> URL {
        root.appendingPathComponent("open")
    }

    /// Writes an armed run, replacing whatever this app id had.
    static func arm(_ run: ArmedRun, in root: URL = root) {
        guard let data = try? encoder.encode(run) else { return }
        writes.sync {
            try? FileManager.default
                .createDirectory(at: openRoot(in: root), withIntermediateDirectories: true)
            try? data.write(to: openURL(forApp: run.record.appid, in: root), options: .atomic)
        }
    }

    /// Forgets an armed run — it has been recorded, or nothing is left that
    /// could say more about it.
    static func disarm(appID: Int, in root: URL = root) {
        writes.sync {
            try? FileManager.default.removeItem(at: openURL(forApp: appID, in: root))
        }
    }

    /// Every run left armed, oldest app id first.
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

    /// Every record of a month, oldest first.
    static func records(inMonth date: Date, in root: URL = root) -> [RunRecord] {
        records(in: url(forMonth: date, in: root))
    }

    /// The most recent records across as many months as it takes, oldest
    /// first.
    ///
    /// By when each launch began, not by when its record was appended: a game
    /// still up when the app quits is written after games that started and
    /// ended while it ran.
    static func recent(_ limit: Int, in root: URL = root) -> [RunRecord] {
        var found: [RunRecord] = []
        for url in monthFiles(in: root).reversed() {
            found = records(in: url) + found
            if found.count >= limit { break }
        }
        return Array(found.sorted { $0.t < $1.t }.suffix(limit))
    }

    /// Compresses every month before this one and drops all but the newest
    /// ``monthsKept``. Cheap enough to run at each app start; it does nothing
    /// on the second call of a month.
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

    /// A month's records, from its plain file or its compressed one. `url`
    /// names either: a `.jsonl` whose month has been compressed is read from
    /// the `.jsonl.z` beside it, and a `.jsonl.z` is decompressed.
    private static func records(in url: URL) -> [RunRecord] {
        let manager = FileManager.default
        var data: Data? = if url.pathExtension == compressedExtension {
            decompressed(at: url)
        } else if manager.fileExists(atPath: url.path) {
            try? Data(contentsOf: url)
        } else {
            decompressed(at: url.appendingPathExtension(compressedExtension))
        }
        guard let data else { return [] }
        return data.split(separator: UInt8(ascii: "\n")).compactMap {
            try? decoder.decode(RunRecord.self, from: Data($0))
        }
    }

    private static func decompressed(at url: URL) -> Data? {
        (try? Data(contentsOf: url)).flatMap { try? ($0 as NSData).decompressed(using: .zlib) as Data }
    }

    /// Every month's file, oldest first — the names sort chronologically.
    private static func monthFiles(in root: URL) -> [URL] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return names.filter { $0.hasSuffix(".jsonl") || $0.hasSuffix(".jsonl.\(compressedExtension)") }
            .sorted()
            .map { root.appendingPathComponent($0) }
    }

    /// Raw zlib, which `NSData` compresses and decompresses without a
    /// subprocess. A month of records is small; the compression is what keeps
    /// a year of them from being a year of files anyone has to think about.
    private static let compressedExtension = "z"

    private static func month(of date: Date) -> String {
        monthStamp.string(from: date)
    }

    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    /// The month a file is named for, in local time: a month boundary is the
    /// one the person reading the directory lives in.
    private static let monthStamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}
