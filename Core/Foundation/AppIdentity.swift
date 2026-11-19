import Foundation

/// What names this installation on the Mac: its folders, logs, defaults,
/// background helper, ports and command-line link.
///
/// A Debug build is a second installation with everything its own: a shared
/// helper label gets a launch requirement only one signature meets, and a
/// shared bottle or port gets two supervisors or bridges. `DEBUG` is set
/// project-wide, so the app, helper and `sevo` agree.
nonisolated enum AppIdentity {
    #if DEBUG
        static let folderName = "Sevoflurane Debug"
        static let logStem = "Sevoflurane-Debug"
        static let identifierStem = "glass.kagerou.sevoflurane.debug"
        /// Added to every loopback port.
        static let portOffset = 10
        /// The `/usr/local/bin` link and MCP server name.
        static let commandName = "sevo-debug"
    #else
        static let folderName = "Sevoflurane"
        static let logStem = "Sevoflurane"
        static let identifierStem = "glass.kagerou.sevoflurane"
        static let portOffset = 0
        static let commandName = "sevo"
    #endif

    /// `~/Library/Application Support/<folder>`.
    static var supportFolder: URL {
        UserHome.url.appendingPathComponent("Library/Application Support/\(folderName)")
    }

    /// `~/Library/Caches/<folder>`, all regenerable.
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
