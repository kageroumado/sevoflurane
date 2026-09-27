import Foundation

/// The dock shim's chronicle, read back.
///
/// The engine's dock shim (dormison `build-macos/dock-shim`) appends a line to
/// `~/Library/Logs/Sevoflurane-windows.log` for every bottle process the
/// moment winemac.drv loads it, and again for each of its windows. The
/// `armed` line names the process's executable before it has drawn anything,
/// which is the only record of a game that dies without a window — three of
/// the five failed launches of the 2026-09-08 playtest were exactly that.
///
/// A line is `HH:mm:ss.SSS <verb> pid=<pid> <exe> <class> "<title>" <W>x<H>`,
/// where the class, title and size are a window's and are empty for a process
/// line. The executable may contain spaces (`The Cat Games.exe`), so it is
/// read as what is left once the window's fields are taken off the end.
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
        // The timestamp, which the reader has no use for: the entries it
        // hands out are the ones it has not seen before.
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

    /// The executable at the head of `<exe> <class> "<title>" <W>x<H>`, whose
    /// three trailing fields are taken off the end because only the
    /// executable can contain a space. A process line has no window, so its
    /// class is empty and two spaces stand where it would be.
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
/// The chronicle is one file for every bottle process and the app is only
/// interested in what happens after a launch is armed, so a tail starts at
/// the file's current end. A file shorter than the offset has been replaced
/// or truncated and is read from its start.
final nonisolated class WineChronicleTail {
    private let url: URL
    private var offset: UInt64
    /// What a read carried that had no newline yet — the shim writes a line
    /// per `fopen`/`fprintf`/`fclose`, but nothing promises a read lands on a
    /// boundary.
    private var partial = ""

    /// Starts at the end of the file, so only what happens from here is read.
    init(url: URL = WineChronicle.url) {
        self.url = url
        offset = Self.size(of: url)
    }

    /// The entries appended since the last call.
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
              let data = try? handle.read(upToCount: Int(size - offset)), !data.isEmpty
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
