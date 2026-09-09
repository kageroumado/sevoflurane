import Foundation

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
        var result = text
        for name in personas where name.count > 2 {
            result = result.replacingOccurrences(of: name, with: persona)
        }
        // The account's own home first: it is the longest match and the one
        // whose replacement is a plain `~` rather than a rewritten prefix.
        result = result.replacingOccurrences(of: NSHomeDirectory(), with: home)
        result = result.replacing(macHome) { _ in home }
        result = result.replacing(windowsUser) { match in "\(match.output.1)~" }
        result = result.replacing(steamIDDigits) { _ in steamID }
        for name in [ProcessInfo.processInfo.hostName, Host.current().localizedName ?? ""]
            where name.count > 2 {
            result = result.replacingOccurrences(of: name, with: host)
        }
        let fullName = NSFullUserName()
        if fullName.count > 2 {
            result = result.replacingOccurrences(of: fullName, with: user)
        }
        return result
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
    nonisolated(unsafe) private static let macHome =
        /\/Users\/(?!Shared(?:\/|$))[^\/\s"':;,\)\]]+/

    /// The user directory of a Windows prefix, on either side of the
    /// translation: `C:\users\<someone>` as Wine prints it and
    /// `drive_c/users/<someone>` as the file system holds it. The prefix is
    /// kept so a reader can still tell which directory it was. `Shared` and
    /// `Public` are the accounts macOS and Windows create for everyone.
    nonisolated(unsafe) private static let windowsUser =
        /(?i)(users[\/\\])(?!(?:Shared|Public)(?:[\/\\]|$))[^\/\\"'\s]+/

    /// A Steam id: the individual-account block, seventeen digits.
    nonisolated(unsafe) private static let steamIDDigits = /\b7656119\d{10}\b/
}
