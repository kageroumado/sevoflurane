import Foundation

/// The last lines of a log file, read from its end: a log grows to megabytes
/// before it rotates, and a tail needs only the part after its last few
/// thousand newlines.
nonisolated enum LogTail {
    /// How much of the file each step back reads.
    private static let chunk: UInt64 = 64 * 1024

    /// The last `count` non-empty lines, oldest first; nil when the file
    /// cannot be opened.
    static func lastLines(of url: URL, count: Int) -> [Substring]? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        var start = size
        var data = Data()
        while start > 0 {
            let step = min(chunk, start)
            start -= step
            try? handle.seek(toOffset: start)
            data = (handle.readData(ofLength: Int(step))) + data
            // One newline more than lines wanted, so the first line kept is whole.
            if data.count(where: { $0 == UInt8(ascii: "\n") }) > count { break }
        }
        let text = String(decoding: data, as: UTF8.self)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        return Array(lines.suffix(count))
    }
}
