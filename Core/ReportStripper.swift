import Foundation

/// What a collected report keeps of a log, and what it takes out.
///
/// ``Redaction`` takes the person out; this takes out what is left that is
/// either useless or unbounded. A line that is nothing but addresses names no
/// symbol and so tells a reader nothing they can act on, and a line a game
/// prints forty thousand times is one line and a count. Both rules exist so
/// that a report can be attached to an issue by someone on a phone.
nonisolated enum ReportStripper {
    /// A line repeated more than this many times is kept once with its count.
    ///
    /// Above three rather than above one: a backtrace through a recursing
    /// frame is the same line several times over, and collapsing that would
    /// take away the shape of the crash (`sevoflurane-unity-mono-stack-overflow`).
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
    static func strip(_ text: String, personas: [String] = []) -> String {
        let redacted = Redaction.apply(to: text, personas: personas)
        let kept = redacted.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !isAddressesOnly($0) }
        return collapsingRepeats(kept).joined(separator: "\n")
    }

    /// Whether a line names nothing a person could look up: hex numbers,
    /// punctuation and whitespace, and no word.
    ///
    /// A hex run that is also a word (`deadbeef`, `cafe`) reads as an address
    /// here, which is what it is in the lines this drops — Wine's bare stack
    /// dumps and the `0x…:  0x… 0x… 0x…` memory rows a crash handler prints.
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

    /// The lines in their first order, each one that ran away carrying how
    /// many times it was printed.
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

    /// The end of a file as a report carries it, with a line saying what was
    /// cut when the file was longer than `limit`.
    static func tail(of url: URL, limit: Int, personas: [String] = []) -> String? {
        guard let (text, elided) = rawTail(of: url, limit: limit) else { return nil }
        return elided + strip(text, personas: personas)
    }

    /// The last `limit` bytes of a file, read from where they start rather
    /// than with the whole file, and the line that says what came before
    /// them (empty when nothing did). `nil` when the file is not there or is
    /// empty.
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
/// The persona and account names there are exactly what a game's log, Steam's
/// own log and an overlay screenshot print, and none of them is derivable from
/// the text — so a report's redaction is given them rather than left to guess.
nonisolated enum SteamAccounts {
    /// Every persona and account name the bottle knows, longest first so a
    /// name that contains another is replaced whole.
    static func names(in steamRoot: URL = SteamBottle.steamRoot) -> [String] {
        let url = steamRoot.appendingPathComponent("config/loginusers.vdf")
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return names(inLoginUsers: text)
    }

    /// The names in a `loginusers.vdf`'s text. The file is Valve's key-value
    /// format: a quoted key, whitespace, a quoted value, one pair per line.
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
