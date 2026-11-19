import Foundation

/// What a collected report keeps of a log, and what it takes out.
///
/// After ``Redaction``, drops lines that are only addresses and collapses
/// repeated lines to one with a count, so a report stays small.
nonisolated enum ReportStripper {
    /// A line repeated more than this many times is kept once with its count.
    /// Three rather than one, so a recursing frame's few repeats keep the crash's shape.
    static let collapseOver = 3

    /// What the manifest says was taken out of every file in a report.
    static let removed = [
        "paths under the home directory, rewritten to ~",
        "the bottle's Windows user, rewritten to ~",
        "this Mac's name and account",
        "Steam ids and persona names",
        "game account ids (uid=)",
        "lines that carry addresses and no symbol",
        "lines repeated more than \(collapseOver) times, kept once with a count",
    ]

    /// A log as a report carries it.
    static func strip(_ text: String, personas: [String] = SteamAccounts.names()) -> String {
        let redacted = Redaction.apply(to: text, personas: personas)
        let kept = redacted.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isAddressesOnly($0) }
        return collapsingRepeats(kept).joined(separator: "\n")
    }

    /// Whether a line is only hex numbers and punctuation, like Wine's bare
    /// stack dumps and `0x…:  0x… 0x…` memory rows. Hex words (`cafe`) count.
    static func isAddressesOnly(_ line: some StringProtocol) -> Bool {
        var sawHex = false
        for token in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let bare = token.trimmingCharacters(in: punctuation)
            if bare.isEmpty { continue }
            let digits = bare.hasPrefix("0x") || bare.hasPrefix("0X")
                ? bare.dropFirst(2) : Substring(bare)
            guard !digits.isEmpty, digits.allSatisfy(\.isHexDigit) else { return false }
            sawHex = true
        }
        return sawHex
    }

    private static let punctuation = CharacterSet(charactersIn: ":,;()[]<>+-|")

    /// Lines past ``collapseOver`` repeats kept once, at first position, with a count.
    private static func collapsingRepeats(
        _ lines: [some StringProtocol],
    ) -> [String] {
        var counts: [String: Int] = [:]
        for line in lines where !line.isEmpty { counts[String(line), default: 0] += 1 }
        var seen: Set<String> = []
        var kept: [String] = []
        for line in lines {
            let text = String(line)
            let count = counts[text] ?? 1
            guard count > collapseOver else {
                kept.append(text)
                continue
            }
            guard seen.insert(text).inserted else { continue }
            kept.append("\(text)  ×\(count)")
        }
        return kept
    }

    /// The stripped last `limit` bytes of a file, with a note of what was cut.
    static func tail(of url: URL, limit: Int, personas: [String] = SteamAccounts.names()) -> String? {
        guard let (text, elided) = rawTail(of: url, limit: limit) else { return nil }
        return elided + strip(text, personas: personas)
    }

    /// The last `limit` bytes of a file, read by seeking, and the elision
    /// note (empty when nothing was cut). `nil` for a missing or empty file.
    static func rawTail(of url: URL, limit: Int) -> (text: String, elided: String)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              let data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        let elided = start > 0 ? "… the first \(start) bytes are not in this report\n" : ""
        return (String(decoding: data, as: UTF8.self), elided)
    }
}

/// The Steam accounts that have signed in inside the bottle, read from the
/// client's own `config/loginusers.vdf`.
///
/// Their persona and account names are what logs print, and redaction cannot
/// detect them, so it is given them.
nonisolated enum SteamAccounts {
    /// Every persona and account name the bottle knows, longest first so a
    /// name that contains another is replaced whole.
    static func names(in steamRoot: URL = SteamBottle.steamRoot) -> [String] {
        let url = steamRoot.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return names(inLoginUsers: text)
    }

    /// The names in a `loginusers.vdf`: quoted key-value pairs, one per line.
    static func names(inLoginUsers text: String) -> [String] {
        var found: Set<String> = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let match = line.firstMatch(of: pair) else { continue }
            guard wanted.contains(String(match.output.1)) else { continue }
            let value = String(match.output.2)
            if value.count > 2 { found.insert(value) }
        }
        return found.sorted { $0.count > $1.count }
    }

    private static let wanted = ["PersonaName", "AccountName"]

    // `nonisolated(unsafe)`: a `Regex` built from a literal holds no state.
    private nonisolated(unsafe) static let pair = /"([A-Za-z]+)"\s+"([^"]*)"/
}
