import Foundation

/// Where the community database's local state lives: the key, the runs
/// waiting to go, and what has been sent.
nonisolated enum StatsStore {
    static let root = ProcessInfo.processInfo.environment["SEVO_STATS_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? AppIdentity.supportFolder.appendingPathComponent("Stats")

    static let identityURL = root.appendingPathComponent("identity.key")
    static let queueURL = root.appendingPathComponent("queue.jsonl")
    static let reportQueueURL = root.appendingPathComponent("reports.jsonl")
    static let reportedURL = root.appendingPathComponent("reported.json")
    static let stateURL = root.appendingPathComponent("state.json")

    /// A run waiting to be sent, and since when.
    struct Queued: Codable, Equatable, Sendable {
        var queued: Date
        var run: SharedRun
    }

    /// A report waiting to be sent, since when, and the run it is about as
    /// the run log names it (``RunRecord/id``), which is how the ledger's
    /// entry is found when the server answers.
    struct QueuedReport: Codable, Equatable, Sendable {
        var queued: Date
        var runID: String
        var report: SharedReport
    }

    /// A report's standing, one per run reported: queued, sent, or refused
    /// with the server's reason. What the run's row reads to say the run was
    /// reported, and what `sevo stats reports` lists.
    struct Reported: Codable, Equatable, Sendable {
        var runID: String
        var verdict: SharedReport.Verdict
        var queued: Date
        var sent: Date?
        var refused: String?
    }

    /// What the server knows of this install, and what it has been sent.
    struct State: Codable, Equatable, Sendable {
        /// The install id the server registered, `nil` before registration.
        var registered: String?
        /// The server's word on the evidence: `attested`, `device`,
        /// `reregistered` or `unverified`.
        var trust: String?
        /// The last sequence number used; every signed request takes the next.
        var seq: Int = 0
        var sentRuns: Int = 0
        /// Optional so a state file written before reports existed still
        /// decodes; a missing count is zero.
        var sentReports: Int?
        var lastSent: Date?
        var lastError: String?
        /// Sends that failed in a row, and when the next may go. Kept on disk
        /// so a relaunch waits out the same backoff rather than starting it
        /// over.
        var failures: Int?
        var nextTry: Date?
    }

    static func readState(from url: URL = stateURL) -> State {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.stats.decode(State.self, from: $0) } ?? State()
    }

    static func writeState(_ state: State, to url: URL = stateURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.stats.encode(state).write(to: url, options: .atomic)
    }

    static func readQueue(from url: URL = queueURL) -> [Queued] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder.stats.decode(Queued.self, from: Data($0.utf8))
        }
    }

    static func writeQueue(_ queue: [Queued], to url: URL = queueURL) {
        writeLines(queue, to: url)
    }

    static func readReportQueue(from url: URL = reportQueueURL) -> [QueuedReport] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").compactMap {
            try? JSONDecoder.stats.decode(QueuedReport.self, from: Data($0.utf8))
        }
    }

    static func writeReportQueue(_ queue: [QueuedReport], to url: URL = reportQueueURL) {
        writeLines(queue, to: url)
    }

    /// Every run reported, oldest first.
    static func readReported(from url: URL = reportedURL) -> [Reported] {
        (try? Data(contentsOf: url)).flatMap { try? JSONDecoder.stats.decode([Reported].self, from: $0) } ?? []
    }

    static func writeReported(_ reported: [Reported], to url: URL = reportedURL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONEncoder.stats.encode(reported).write(to: url, options: .atomic)
    }

    /// Writes one run's standing, replacing what the run had.
    static func noteReported(_ entry: Reported, in url: URL = reportedURL) {
        var reported = readReported(from: url).filter { $0.runID != entry.runID }
        reported.append(entry)
        writeReported(reported, to: url)
    }

    static func reported(forRun runID: String, in url: URL = reportedURL) -> Reported? {
        readReported(from: url).first { $0.runID == runID }
    }

    private static func writeLines(_ items: [some Encodable], to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = items.compactMap { try? JSONEncoder.stats.encode($0) }
            .map { String(decoding: $0, as: UTF8.self) + "\n" }
        try? Data(lines.joined().utf8).write(to: url, options: .atomic)
    }
}

nonisolated extension JSONEncoder {
    static var stats: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}

nonisolated extension JSONDecoder {
    static var stats: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
