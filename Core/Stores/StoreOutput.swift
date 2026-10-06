import Foundation

/// A title a store account owns that runs on Windows.
nonisolated struct StoreTitle: Codable, Equatable, Sendable, Identifiable {
    let store: GameStore
    /// The store's own id: Epic's app name, GOG's product id.
    let id: String
    let title: String
    /// Box or tile art, when the store names one.
    let art: URL?
    /// The current build, for a store whose listing names it.
    var version: String?
}

/// A title installed through a store client.
nonisolated struct StoreInstall: Codable, Equatable, Sendable, Identifiable {
    let store: GameStore
    let id: String
    let title: String
    /// The game's folder, as a macOS path.
    let path: String
    /// The installed build: Epic's build version, GOG's build id.
    var version: String
    /// The version's name where it differs from the build, for display.
    var versionName: String?
    /// Bytes on disk, when the client recorded them.
    var size: Int64?
}

/// What starts an installed title: its executable, the folder it starts in
/// and its arguments, sign-in arguments included.
nonisolated struct StoreLaunchPlan: Equatable, Sendable {
    /// The game's own folder, which the executable and the working folder
    /// must lie in (``StorePaths/accepts(_:roots:protected:)``).
    let folder: String
    let executable: String
    let workingDirectory: String
    let arguments: [String]
}

/// How far a client's download or check has come, as its own log lines say.
nonisolated struct StoreProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case downloading, checking }

    var phase: Phase
    /// 0…1.
    var fraction: Double
    /// Bytes written so far and in all, when the line names them.
    var bytesDone: Int64?
    var bytesTotal: Int64?
}

/// The parts of the clients' output that are not JSON: log lines and the
/// argument strings stores publish.
nonisolated enum StoreOutput {
    /// A log line without the `[logger] LEVEL: ` both clients put before it.
    static func stripLogPrefix(_ line: String) -> String {
        guard line.hasPrefix("["), let close = line.firstIndex(of: "]") else { return line }
        let rest = line[line.index(after: close)...].drop { $0 == " " }
        for level in ["DEBUG: ", "INFO: ", "WARNING: ", "ERROR: ", "CRITICAL: ", "FATAL: "] where rest.hasPrefix(level) {
            return String(rest.dropFirst(level.count))
        }
        return String(rest)
    }

    /// Reads one line of progress from either client.
    ///
    /// - legendary's download manager: `= Progress: 12.34% (123/1000), Running for …`
    /// - legendary's file check: `Verification progress: 12/345 (3.5%) [10.0 MiB/s]`
    /// - gogdl: `= Progress: 12.34 123456/1000000, Running for: …`, whose
    ///   numbers are bytes written and bytes in all.
    static func progress(_ line: String) -> StoreProgress? {
        let text = stripLogPrefix(line).trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("Verification progress:") {
            guard let percent = number(between: "(", and: "%)", in: text) else { return nil }
            return StoreProgress(phase: .checking, fraction: clamp(percent / 100))
        }
        guard text.hasPrefix("= Progress:") else { return nil }
        let body = text.dropFirst("= Progress:".count).trimmingCharacters(in: .whitespaces)
        let fields = body.split(separator: " ", maxSplits: 2)
        guard let first = fields.first else { return nil }
        if first.hasSuffix("%") {
            guard let percent = Double(first.dropLast()) else { return nil }
            return StoreProgress(phase: .downloading, fraction: clamp(percent / 100))
        }
        guard let percent = Double(first), fields.count > 1 else { return nil }
        let counts = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: ",")).split(separator: "/")
        var progress = StoreProgress(phase: .downloading, fraction: clamp(percent / 100))
        if counts.count == 2, let done = Int64(counts[0]), let total = Int64(counts[1]), total > 0 {
            progress.bytesDone = done
            progress.bytesTotal = total
        }
        return progress
    }

    /// The download size legendary announces before it starts, in bytes:
    /// `Download size: 1234.56 MiB (Compression savings: …)`.
    static func legendaryDownloadSize(_ line: String) -> Int64? {
        let text = stripLogPrefix(line)
        guard text.hasPrefix("Download size: "),
              let mebibytes = Double(text.dropFirst("Download size: ".count).prefix { $0 != " " }) else { return nil }
        return Int64(mebibytes * 1_048_576)
    }

    /// Splits an argument string a store publishes into tokens: spaces part
    /// them, double quotes group them and are dropped, and backslashes stay,
    /// because they are Windows paths.
    static func splitArguments(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        var started = false
        for character in text {
            if character == "\"" {
                quoted.toggle()
                started = true
            } else if character == " ", !quoted {
                if started { tokens.append(current) }
                current = ""
                started = false
            } else {
                current.append(character)
                started = true
            }
        }
        if started { tokens.append(current) }
        return tokens
    }

    private static func number(between open: String, and close: String, in text: String) -> Double? {
        guard let end = text.range(of: close),
              let start = text[..<end.lowerBound].range(of: open, options: .backwards) else { return nil }
        return Double(text[start.upperBound ..< end.lowerBound])
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}
