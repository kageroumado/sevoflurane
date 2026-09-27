import Foundation

/// What names this installation on the Mac: its folders, logs, defaults,
/// background helper, ports and command-line link.
///
/// A Debug build is a second installation beside the shipping one, with its
/// own bottle, engines, settings and helper, so running it from Xcode leaves
/// the installed app untouched. Sharing any one of these would let the two
/// collide: a helper registered under one label by two differently signed
/// apps gets a launch requirement only one of them meets, two supervisors
/// would drive one bottle's Wine, and two bridges would race for one port.
/// `DEBUG` is set project-wide, so the app, its helper and `sevo` built
/// together always agree on which installation they are.
nonisolated enum AppIdentity {
    #if DEBUG
        /// The name of this installation's folders under `~/Library`.
        static let folderName = "Sevoflurane Debug"
        /// The stem of this installation's log files in `~/Library/Logs`.
        static let logStem = "Sevoflurane-Debug"
        /// The reverse-DNS stem every identifier this installation mints starts from.
        static let identifierStem = "glass.kagerou.sevoflurane.debug"
        /// Added to every loopback port, keeping this installation's in a
        /// block of its own.
        static let portOffset = 10
        /// The name `sevo` is linked under in `/usr/local/bin`, and the name
        /// its MCP server registers under with the agents.
        static let commandName = "sevo-debug"
    #else
        static let folderName = "Sevoflurane"
        static let logStem = "Sevoflurane"
        static let identifierStem = "glass.kagerou.sevoflurane"
        static let portOffset = 0
        static let commandName = "sevo"
    #endif

    /// `~/Library/Application Support/<folder>`, the root of everything this
    /// installation keeps: bottles, engines, runs, reports and settings.
    static var supportFolder: URL {
        UserHome.url.appendingPathComponent("Library/Application Support/\(folderName)")
    }

    /// `~/Library/Caches/<folder>`: art, icons and rewritten assets, all
    /// regenerable.
    static var cachesFolder: URL {
        UserHome.url.appendingPathComponent("Library/Caches/\(folderName)")
    }

    /// A log file in `~/Library/Logs`: `suffix` nil for the event log,
    /// `"wine"` for `<stem>-wine.log`.
    static func logFile(_ suffix: String? = nil) -> URL {
        let name = suffix.map { "\(logStem)-\($0)" } ?? logStem
        return UserHome.url.appending(path: "Library/Logs/\(name).log")
    }
}
