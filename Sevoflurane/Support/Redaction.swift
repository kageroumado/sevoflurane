import Foundation
import SystemConfiguration

/// Takes the person out of text that is meant to be shared.
///
/// Everything a report carries — a run record, a game's own log, an env file —
/// was written by software with no reason to keep the account out of it: a
/// Unity player logs its data path, Wine logs `C:\users\<you>`, Steam logs the
/// signed-in id. The rewrites below are the ones that can be made without
/// reading the text: a path under a home directory becomes `~`, the bottle's
/// Windows user becomes `~`, this Mac's name and account become placeholders,
/// and anything shaped like a Steam id becomes `<steamid>`.
///
/// A persona name is not derivable from a string, so a caller that knows one
/// passes it in.
nonisolated enum Redaction {
    static let home = "~"
    static let steamID = "<steamid>"
    static let persona = "<persona>"
    static let host = "<host>"
    static let user = "<user>"

    /// `text` with this Mac's account, any home directory, the bottle's
    /// Windows user, the machine's name and every Steam id taken out.
    static func apply(to text: String, personas: [String] = []) -> String {
        guard text.utf8.count > lineWiseThreshold else { return redact(text, personas: personas) }
        return redactingMatchingLines(of: text, personas: personas)
    }

    /// Texts past this size are redacted line by line, and only the lines a
    /// cheap search says can carry something: a bug report's logs run to tens
    /// of megabytes, nearly all of it lines with nothing to take out, and the
    /// patterns below cost seconds per megabyte.
    private static let lineWiseThreshold = 64 * 1024

    private static func redactingMatchingLines(of text: String, personas: [String]) -> String {
        let needles = ([
            "sers/",
            "sers\\",
            "7656119",
            NSUserName(),
            NSFullUserName(),
        ] + machineNames + personas)
            .filter { $0.count > 2 }
            .map(NSRegularExpression.escapedPattern(for:))
        guard let search = try? NSRegularExpression(
            pattern: needles.joined(separator: "|"), options: [.caseInsensitive],
        ) else { return redact(text, personas: personas) }

        let source = text as NSString
        let result = NSMutableString(capacity: source.length)
        var copied = 0
        search.enumerateMatches(in: text, range: NSRange(location: 0, length: source.length)) { match, _, _ in
            guard let match, match.range.location >= copied else { return }
            let line = source.lineRange(for: match.range)
            result.append(source.substring(with: NSRange(location: copied, length: line.location - copied)))
            result.append(redact(source.substring(with: line), personas: personas))
            copied = NSMaxRange(line)
        }
        result.append(source.substring(from: copied))
        return result as String
    }

    /// What this Mac is called: the kernel's host name, and the computer and
    /// Bonjour names from Sharing settings, longest first so a name that
    /// contains another is replaced whole. All three are local reads.
    /// `ProcessInfo.hostName` and `Host.current()` resolve the name over the
    /// network, and hold the caller for half a minute where the resolver
    /// does not answer.
    private static let machineNames: [String] = {
        var kernelName = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        let names = [
            gethostname(&kernelName, kernelName.count - 1) == 0 ? String(cString: kernelName) : nil,
            SCDynamicStoreCopyComputerName(nil, nil) as String?,
            SCDynamicStoreCopyLocalHostName(nil) as String?,
        ]
        return Set(names.compactMap(\.self).filter { $0.count > 2 })
            .sorted { ($0.count, $0) > ($1.count, $1) }
    }()

    private static func redact(_ text: String, personas: [String]) -> String {
        var result = text
        for name in personas where name.count > 2 {
            result = result.replacingOccurrences(of: name, with: persona)
        }
        // The account's own home first: it is the longest match and the one
        // whose replacement is a plain `~` rather than a rewritten prefix.
        result = result.replacingOccurrences(of: UserHome.path, with: home)
        result = result.replacing(macHome) { _ in home }
        result = result.replacing(windowsUser) { match in "\(match.output.1)~" }
        result = result.replacing(steamIDDigits) { _ in steamID }
        for name in machineNames {
            result = result.replacingOccurrences(of: name, with: host)
        }
        let fullName = NSFullUserName()
        if fullName.count > 2 {
            result = result.replacingOccurrences(of: fullName, with: user)
        }
        return removingAccountName(from: result)
    }

    /// The account's short name standing on its own, once every path that
    /// contains it has already become `~`. Unreal writes `LogInit: User:
    /// <name>` with nothing around it, and a name is what a report may not
    /// carry however it is spelled.
    private static func removingAccountName(from text: String) -> String {
        let name = NSUserName()
        guard name.count > 2 else { return text }
        let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        else { return text }
        return regex.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex ..< text.endIndex, in: text),
            withTemplate: user,
        )
    }

    /// A file's path as a report may carry it.
    static func apply(to url: URL) -> String {
        apply(to: url.path)
    }

    // The three patterns are `nonisolated(unsafe)` because `Regex` is not
    // `Sendable`: a regex built from a literal carries no transform that could
    // hold state, and matching never mutates it.

    /// `/Users/<someone>`, which is the whole of what a macOS path says about
    /// a person. `/Users/Shared` names no one and is left alone.
    private nonisolated(unsafe) static let macHome =
        /\/Users\/(?!Shared(?:\/|$))[^\/\s"':;,\)\]]+/

    /// The user directory of a Windows prefix, on either side of the
    /// translation: `C:\users\<someone>` as Wine prints it and
    /// `drive_c/users/<someone>` as the file system holds it. The prefix is
    /// kept so a reader can still tell which directory it was. `Shared` and
    /// `Public` are the accounts macOS and Windows create for everyone.
    private nonisolated(unsafe) static let windowsUser =
        /(?i)(users[\/\\])(?!(?:Shared|Public)(?:[\/\\]|$))[^\/\\"'\s]+/

    /// A Steam id: the individual-account block, seventeen digits.
    private nonisolated(unsafe) static let steamIDDigits = /\b7656119\d{10}\b/
}
