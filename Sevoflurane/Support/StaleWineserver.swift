import Darwin
import Foundation

/// A wineserver that holds the bottle's socket and answers no one: every
/// launch against the bottle then prints Wine's own "cannot connect" line and
/// exits, and the client never comes back until that server is gone.
nonisolated enum StaleWineserver {
    /// The pid Wine names in "a wine server seems to be running, but I cannot
    /// connect to it … (it might be pid 45089)", from the last such line in `text`.
    static func pid(in text: String) -> pid_t? {
        guard text.contains("a wine server seems to be running, but I cannot connect to it") else { return nil }
        guard let match = text.ranges(of: /it might be pid (\d+)/).last else { return nil }
        let digits = text[match].split(separator: " ").last?.filter(\.isNumber) ?? ""
        return pid_t(digits)
    }

    /// The last `limit` bytes of Wine's log.
    static func logTail(limit: Int = 16384, url: URL = WineLog.fileURL) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    /// Ends the named process when it is a wineserver, and answers whether it did.
    static func end(_ pid: pid_t) -> Bool {
        var path = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0,
              String(cString: path).hasSuffix("/wineserver")
        else { return false }
        return kill(pid, SIGKILL) == 0
    }
}
