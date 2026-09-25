import Foundation

/// Where the community database's local state lives: the key, the runs
/// waiting to go, and what has been sent.
nonisolated enum StatsStore {
    static let root = ProcessInfo.processInfo.environment["SEVO_STATS_DIR"]
        .map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        ?? UserHome.url.appendingPathComponent("Library/Application Support/Sevoflurane/Stats")

    static let identityURL = root.appendingPathComponent("identity.key")
    static let queueURL = root.appendingPathComponent("queue.jsonl")
    static let stateURL = root.appendingPathComponent("state.json")

    /// A run waiting to be sent, and since when.
    struct Queued: Codable, Equatable, Sendable {
        var queued: Date
        var run: SharedRun
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
        var lastSent: Date?
        var lastError: String?
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
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let lines = queue.compactMap { try? JSONEncoder.stats.encode($0) }
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
