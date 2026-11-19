import Foundation
import SystemConfiguration

/// Takes the person out of text that is meant to be shared.
///
/// Home paths and the bottle's Windows user become `~`, this Mac's name and
/// account become placeholders, Steam ids in each of their forms (the
/// seventeen digits, `[U:1:…]`, the `userdata` folder) become `<steamid>`,
/// and `uid=` or `UID:` numbers become `<uid>`. Persona and account names
/// cannot be detected, so they are the ones the bottle's Steam has signed in
/// unless a caller passes its own.
nonisolated enum Redaction {
    static let home = "~"
    static let steamID = "<steamid>"
    static let persona = "<persona>"
    static let host = "<host>"
    static let user = "<user>"
    static let gameAccount = "<uid>"

    /// `text` with the person taken out.
    static func apply(to text: String, personas: [String] = SteamAccounts.names()) -> String {
        guard text.utf8.count > lineWiseThreshold else { return redact(text, personas: personas) }
        return redactingMatchingLines(of: text, personas: personas)
    }

    /// Past this size only lines a cheap search flags are redacted: the
    /// patterns cost seconds per megabyte, and logs run to tens of megabytes.
    private static let lineWiseThreshold = 64 * 1024

    private static func redactingMatchingLines(of text: String, personas: [String]) -> String {
        let needles = ([
            "sers/",
            "sers\\",
            "7656119",
            "U:1:",
            "userdata",
            "uid",
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

    /// The kernel, computer and Bonjour names, longest first so a name that
    /// contains another is replaced whole. Never use `ProcessInfo.hostName` or
    /// `Host.current()`: they resolve over the network and can block 30 s.
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
        // The account's own home first: the longest match, replaced by plain `~`.
        result = result.replacingOccurrences(of: UserHome.path, with: home)
        result = result.replacing(macHome) { _ in home }
        result = result.replacing(windowsUser) { match in "\(match.output.1)~" }
        result = result.replacing(steamIDDigits) { _ in steamID }
        result = result.replacing(steam3ID) { _ in steamID }
        result = result.replacing(userdataFolder) { match in "\(match.output.1)\(steamID)" }
        result = result.replacing(gameAccountID) { match in "\(match.output.1)\(gameAccount)" }
        for name in machineNames {
            result = result.replacingOccurrences(of: name, with: host)
        }
        let fullName = NSFullUserName()
        if fullName.count > 2 {
            result = result.replacingOccurrences(of: fullName, with: user)
        }
        return removingAccountName(from: result)
    }

    /// The account's short name standing alone, after paths are gone, as in
    /// Unreal's `LogInit: User: <name>`.
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

    // `nonisolated(unsafe)`: `Regex` is not `Sendable`, but a literal regex
    // holds no state.

    /// `/Users/<someone>`, except `/Users/Shared`.
    private nonisolated(unsafe) static let macHome =
        /\/Users\/(?!Shared(?:\/|$))[^\/\s"':;,\)\]]+/

    /// `C:\users\<someone>` or `drive_c/users/<someone>`, keeping the prefix;
    /// `Shared` and `Public` are left alone.
    private nonisolated(unsafe) static let windowsUser =
        /(?i)(users[\/\\])(?!(?:Shared|Public)(?:[\/\\]|$))[^\/\\"'\s]+/

    /// A game account's number after `uid=` or `UID:`, as HoYoverse logs it.
    private nonisolated(unsafe) static let gameAccountID =
        /(?i)(\buid\s*[=:]\s*)\d{5,}/

    /// A seventeen-digit individual-account Steam id.
    private nonisolated(unsafe) static let steamIDDigits = /\b7656119\d{10}\b/

    /// The same account as Steam's own logs write it, `[U:1:845470373]`: the
    /// number added to 76561197960265728 is the seventeen-digit id.
    private nonisolated(unsafe) static let steam3ID = /\[?U:1:\d+\]?/

    /// The account's folder under `userdata`, keeping the prefix.
    private nonisolated(unsafe) static let userdataFolder = /(?i)(userdata[\/\\])\d+/
}
