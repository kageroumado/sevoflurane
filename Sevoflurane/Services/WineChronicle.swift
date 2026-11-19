import Foundation

/// The dock shim's chronicle, read back.
///
/// The engine's dock shim (dormison `build-macos/dock-shim`) appends a line to
/// `~/Library/Logs/Sevoflurane-windows.log` for every bottle process when
/// winemac.drv loads it, and for each of its windows. The `armed` line is the
/// only record of a game that dies without a window.
///
/// A line is `HH:mm:ss.SSS <verb> pid=<pid> <exe> <class> "<title>" <W>x<H>`;
/// the window fields are empty for a process line. The executable may
/// contain spaces (`The Cat Games.exe`), so it is what remains once the
/// window fields are taken off the end.
nonisolated enum WineChronicle {
    /// What the shim was reporting.
    enum Verb: String, Sendable {
        /// A bottle process loaded winemac.drv.
        case armed
        /// The driver set the process's Dock icon, which it does once a Win32
        /// window exists.
        case shaped
        /// A window reached the screen.
        case passed
        /// A window was kept off the screen (the client's own plumbing).
        case suppressed
        /// The shim asked whether to suppress a window and let it through.
        case asked
    }

    struct Entry: Equatable, Sendable {
        let verb: Verb
        let pid: pid_t
        /// The executable as the shim spells it, case intact.
        let executable: String
    }

    static let url = AppIdentity.logFile("windows")

    /// One line, or `nil` for anything that is not one.
    static func parse(_ line: some StringProtocol) -> Entry? {
        var rest = Substring(line)
        // Skips the timestamp.
        guard let afterTime = rest.firstIndex(of: " ") else { return nil }
        rest = rest[rest.index(after: afterTime)...]
        guard let afterVerb = rest.firstIndex(of: " "),
              let verb = Verb(rawValue: String(rest[..<afterVerb])) else { return nil }
        rest = rest[rest.index(after: afterVerb)...]
        guard let afterPID = rest.firstIndex(of: " "),
              rest[..<afterPID].hasPrefix("pid="),
              let pid = pid_t(rest[..<afterPID].dropFirst("pid=".count)) else { return nil }
        rest = rest[rest.index(after: afterPID)...]
        guard let executable = executable(fromTail: rest) else { return nil }
        return Entry(verb: verb, pid: pid, executable: executable)
    }

    /// The executable at the head of `<exe> <class> "<title>" <W>x<H>`. A
    /// process line's empty class leaves two spaces.
    private static func executable(fromTail tail: Substring) -> String? {
        guard let sizeStart = tail.lastIndex(of: " ") else { return nil }
        var head = tail[..<sizeStart]
        guard let titleStart = head.dropLast().lastIndex(of: "\"") else { return nil }
        head = head[..<titleStart]
        guard head.hasSuffix(" ") else { return nil }
        head = head.dropLast()
        if head.hasSuffix(" ") {
            head = head.dropLast()
        } else if let classStart = head.lastIndex(of: " ") {
            head = head[..<classStart]
        }
        return head.isEmpty ? nil : String(head)
    }
}

/// Reads what the shim has appended since the last read.
///
/// A tail starts at the file's current end. A file shorter than the offset
/// was replaced or truncated and is read from its start.
final nonisolated class WineChronicleTail {
    private let url: URL
    private var offset: UInt64
    /// What a read carried that had no newline yet.
    private var partial = ""

    init(url: URL = WineChronicle.url) {
        self.url = url
        offset = Self.size(of: url)
    }

    /// The most one call reads; the rest comes in later calls. Parsing a
    /// 3.7 MB backlog at once held the main thread for 0.2 s.
    static let maximumBytesPerRead: UInt64 = 512 * 1024

    /// The entries appended since the last call, up to ``maximumBytesPerRead``.
    func newEntries() -> [WineChronicle.Entry] {
        let size = Self.size(of: url)
        if size < offset {
            offset = 0
            partial = ""
        }
        guard size > offset else { return [] }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: offset)) != nil,
              let data = try? handle.read(upToCount: Int(min(size - offset, Self.maximumBytesPerRead))),
              !data.isEmpty
        else { return [] }
        offset += UInt64(data.count)
        var text = partial + String(decoding: data, as: UTF8.self)
        partial = ""
        if let lastBreak = text.lastIndex(of: "\n") {
            partial = String(text[text.index(after: lastBreak)...])
            text = String(text[..<lastBreak])
        } else {
            partial = text
            return []
        }
        return text.split(separator: "\n").compactMap(WineChronicle.parse)
    }

    private static func size(of url: URL) -> UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }
}
