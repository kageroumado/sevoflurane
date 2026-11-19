import Foundation

/// A macOS crash report (`.ips`) as a collected report carries it.
///
/// The file is a one-line JSON header, then a JSON body. The render keeps the
/// exception, the faulting thread and our own images, with paths whole for
/// ``ReportStripper`` to redact.
nonisolated enum CrashReportIPS {
    /// The header's `procName`, the body's `procPath`, and when the report
    /// was written.
    struct Identity: Sendable, Equatable {
        let process: String
        /// From the body's opening keys.
        let path: String?
        let timestamp: Date?
    }

    /// The header and `procPath`, from the opening kilobytes alone.
    static func identity(of url: URL) -> Identity? {
        guard let opening = opening(of: url),
              let split = opening.firstIndex(of: UInt8(ascii: "\n")),
              let header = try? JSONSerialization.jsonObject(with: opening[..<split])
              as? [String: Any] else { return nil }
        let name = header["procName"] as? String ?? header["name"] as? String
        guard let name else { return nil }
        let body = String(decoding: opening[opening.index(after: split)...], as: UTF8.self)
        return Identity(
            process: name,
            path: body.firstMatch(of: procPath).map { unescaped(String($0.1)) },
            timestamp: (header["timestamp"] as? String).flatMap(reportStamp.date(from:)),
        )
    }

    /// Whether a report is ours: by file-name prefix, or for a game's launcher
    /// bundle (named `<Title>-<date>.ips`) by a `procPath` holding one of
    /// `pathMarkers`.
    static func isOurs(_ url: URL, prefixes: [String], pathMarkers: [String]) -> Bool {
        let name = url.lastPathComponent
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        guard let path = identity(of: url)?.path else { return false }
        return pathMarkers.contains { path.contains($0) }
    }

    /// The report rendered down; `ours` picks the images listed, the rest
    /// counted.
    static func render(_ url: URL, ours: (String) -> Bool) -> String? {
        guard let data = try? Data(contentsOf: url),
              let split = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
        let body = data[data.index(after: split)...]
        guard let report = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return nil }
        var lines = heading(of: report, named: url.lastPathComponent)
        let images = (report["usedImages"] as? [[String: Any]]) ?? []
        lines += faultingThread(of: report, images: images)
        lines += ourImages(images, ours: ours)
        return lines.joined(separator: "\n") + "\n"
    }

    /// What died, when, and how.
    private static func heading(of report: [String: Any], named file: String) -> [String] {
        var lines = ["# \(file)"]
        for (label, key) in [("process", "procName"), ("path", "procPath"), ("os", "osVersion")] {
            guard let value = report[key] else { continue }
            lines.append("\(label): \(describe(value))")
        }
        if let pid = report["pid"] { lines.append("pid: \(describe(pid))") }
        if let exception = report["exception"] as? [String: Any] {
            for key in ["type", "signal", "subtype", "codes"] {
                guard let value = exception[key] else { continue }
                lines.append("\(key): \(describe(value))")
            }
        }
        if let termination = report["termination"] as? [String: Any] {
            lines.append("termination: \(describe(termination))")
        }
        return lines
    }

    /// The faulting thread, frame by frame.
    private static func faultingThread(
        of report: [String: Any], images: [[String: Any]],
    ) -> [String] {
        guard let threads = report["threads"] as? [[String: Any]] else { return [] }
        let index = report["faultingThread"] as? Int ?? 0
        guard threads.indices.contains(index) else { return [] }
        let thread = threads[index]
        var lines = ["", "faulting thread \(index)\(thread["queue"].map { " (\(describe($0)))" } ?? ""):"]
        let frames = (thread["frames"] as? [[String: Any]]) ?? []
        for (number, frame) in frames.prefix(maximumFrames).enumerated() {
            lines.append("  \(number)  \(describe(frame, in: images))")
        }
        if frames.count > maximumFrames {
            lines.append("  … \(frames.count - maximumFrames) further frames")
        }
        return lines
    }

    /// Deeper frames are the runtime's start-up, the same in every report.
    private static let maximumFrames = 64

    /// Image, symbol when known, and the offset symbolication needs.
    private static func describe(_ frame: [String: Any], in images: [[String: Any]]) -> String {
        let index = frame["imageIndex"] as? Int
        let image = index.flatMap { images.indices.contains($0) ? images[$0] : nil }
        let name = image?["name"] as? String ?? "?"
        let offset = frame["imageOffset"] as? Int ?? 0
        guard let symbol = frame["symbol"] as? String else {
            return "\(name) + \(offset)"
        }
        let location = frame["symbolLocation"] as? Int ?? 0
        return "\(name)  \(symbol) + \(location)  (+\(offset))"
    }

    /// Our images with their UUIDs; the rest counted.
    private static func ourImages(
        _ images: [[String: Any]], ours: (String) -> Bool,
    ) -> [String] {
        var lines = ["", "images:"]
        var others = 0
        for image in images {
            let path = image["path"] as? String ?? ""
            guard ours(path) else {
                others += 1
                continue
            }
            let name = image["name"] as? String ?? (path as NSString).lastPathComponent
            let uuid = image["uuid"] as? String ?? "?"
            lines.append("  \(name)  \(uuid)  \(path)")
        }
        lines.append("  … \(others) system images")
        return lines
    }

    private static func describe(_ value: Any) -> String {
        if let dictionary = value as? [String: Any] {
            return dictionary.keys.sorted().map { "\($0)=\(describe(dictionary[$0]!))" }
                .joined(separator: " ")
        }
        return String(describing: value)
    }

    /// The header line and the body's opening, where `procPath` sits.
    private static func opening(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: openingBytes)
    }

    private static let openingBytes = 8192

    // `nonisolated(unsafe)`: a `Regex` built from a literal holds no state.
    private nonisolated(unsafe) static let procPath = /"procPath"\s*:\s*"((?:[^"\\]|\\.)*)"/

    /// The report writes every `/` as `\/`.
    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// The header's timestamp format.
private nonisolated let reportStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// What a Windows minidump says about itself without being opened.
///
/// A dump holds the process's memory, so levels 0 and 1 keep only its size
/// and loaded modules. The module list is stream type 4, each name a UTF-16
/// string at its own offset.
nonisolated struct MinidumpMetadata: Sendable, Equatable {
    let bytes: Int
    let modules: [String]

    /// `nil` for a file that is not a minidump.
    static func read(_ url: URL) -> MinidumpMetadata? {
        // Mapped: a dump is a process's memory, gigabytes of it, and only its header is read.
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), data.count >= headerBytes,
              data.prefix(4).elementsEqual(signature) else { return nil }
        let streamCount = Int(data.integer(UInt32.self, at: 8) ?? 0)
        let directory = Int(data.integer(UInt32.self, at: 12) ?? 0)
        for index in 0 ..< min(streamCount, maximumStreams) {
            let entry = directory + index * directoryEntryBytes
            guard data.integer(UInt32.self, at: entry) == moduleListStream,
                  let offset = data.integer(UInt32.self, at: entry + 8) else { continue }
            return MinidumpMetadata(
                bytes: data.count, modules: modules(in: data, at: Int(offset)),
            )
        }
        return MinidumpMetadata(bytes: data.count, modules: [])
    }

    /// A count, then one fixed-size record per module.
    private static func modules(in data: Data, at offset: Int) -> [String] {
        guard let count = data.integer(UInt32.self, at: offset) else { return [] }
        var found: [String] = []
        for index in 0 ..< min(Int(count), maximumModules) {
            let record = offset + 4 + index * moduleRecordBytes
            guard let nameOffset = data.integer(UInt32.self, at: record + moduleNameField),
                  let name = string(in: data, at: Int(nameOffset)) else { continue }
            // `NSString.lastPathComponent` ignores backslashes.
            found.append(
                name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
                    ?? name,
            )
        }
        return found
    }

    /// A byte length, then that many bytes of UTF-16.
    private static func string(in data: Data, at offset: Int) -> String? {
        guard let length = data.integer(UInt32.self, at: offset), length > 0,
              length < maximumStringBytes else { return nil }
        let start = data.startIndex + offset + 4
        let end = start + Int(length)
        guard end <= data.endIndex else { return nil }
        let units = stride(from: start, to: end - 1, by: 2).compactMap { index -> UInt16? in
            UInt16(data[index]) | (UInt16(data[index + 1]) << 8)
        }
        return String(decoding: units, as: UTF16.self)
    }

    var summary: String {
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        guard !modules.isEmpty else { return "\(size), module list unreadable" }
        return "\(size), \(modules.count) modules: \(modules.joined(separator: ", "))"
    }

    private static let signature = Data("MDMP".utf8)
    private static let headerBytes = 32
    private static let directoryEntryBytes = 12
    private static let moduleRecordBytes = 108
    /// `MINIDUMP_MODULE.ModuleNameRva`, after the base, size, checksum and
    /// timestamp that open the record.
    private static let moduleNameField = 20
    private static let moduleListStream: UInt32 = 4
    private static let maximumStreams = 64
    private static let maximumModules = 512
    private static let maximumStringBytes: UInt32 = 4096
}

private nonisolated extension Data {
    /// A little-endian integer at `offset`, `nil` past the end.
    func integer<Value: FixedWidthInteger>(_: Value.Type, at offset: Int) -> Value? {
        let start = startIndex + offset
        let end = start + MemoryLayout<Value>.size
        guard offset >= 0, end <= endIndex else { return nil }
        return self[start ..< end].reversed().reduce(Value.zero) { $0 << 8 | Value($1) }
    }
}
