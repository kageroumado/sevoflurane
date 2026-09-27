import Foundation

/// A macOS crash report (`.ips`) as a collected report carries it.
///
/// The file is two JSON documents: a one-line header naming the process and
/// the moment, then the body with the threads, the exception and every image
/// that was mapped. A whole one is hundreds of kilobytes of thread state and
/// system libraries; what answers "why did this die" is the exception, the
/// thread that took it, and the images that are ours — the engine, the
/// renderer, D3DMetal. The rest is dropped.
///
/// The render keeps paths whole; taking the person out of them is
/// ``ReportStripper``'s job, once, over the finished text.
nonisolated enum CrashReportIPS {
    /// The header's `procName`, the body's `procPath`, and when the report
    /// was written.
    struct Identity: Sendable, Equatable {
        let process: String
        /// The executable that died. The header names only the process, so
        /// this comes from the body, whose opening keys carry it.
        let path: String?
        let timestamp: Date?
    }

    /// The header of a report and the path at the head of its body, from the
    /// opening kilobytes alone.
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

    /// Whether a report is one of this project's processes.
    ///
    /// The engine's own executables are known by name, so their reports are
    /// matched by `prefixes`. A Wine game runs through its launcher bundle,
    /// `~/Library/Application Support/Sevoflurane/Launchers/<appid>/<Title>.app`,
    /// and macOS names its report after the bundle: `<Title>-<date>.ips`,
    /// which no list of prefixes can anticipate. That report is recognized by
    /// its `procPath`, which sits inside the bundle and so contains one of
    /// `pathMarkers`.
    static func isOurs(_ url: URL, prefixes: [String], pathMarkers: [String]) -> Bool {
        let name = url.lastPathComponent
        if prefixes.contains(where: { name.hasPrefix($0) }) { return true }
        guard let path = identity(of: url)?.path else { return false }
        return pathMarkers.contains { path.contains($0) }
    }

    /// The report, rendered down to what a person can act on. `ours` decides
    /// which images are kept whole — everything else is named by count only.
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

    /// The thread that took the exception, frame by frame, each named by its
    /// image and its offset in it.
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

    /// How deep a backtrace is kept. Past this it is the runtime's own
    /// start-up frames, which are the same in every report.
    private static let maximumFrames = 64

    /// One frame: the image it sits in, the symbol when the report has one,
    /// and the offset that a symbolication would need.
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

    /// The images the run's own software contributed, named with the build
    /// each one came from; everything else is counted rather than listed.
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

    /// The first kilobytes of a report: the whole header line and the opening
    /// of the body, where `procPath` sits.
    private static func opening(of url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? handle.read(upToCount: openingBytes)
    }

    private static let openingBytes = 8192

    // `nonisolated(unsafe)`: a `Regex` built from a literal holds no state.
    // The body is pretty-printed JSON, so the value is quoted and any quote
    // or backslash inside it is escaped.
    private nonisolated(unsafe) static let procPath = /"procPath"\s*:\s*"((?:[^"\\]|\\.)*)"/

    /// A JSON string's slashes as the path has them: the report writes every
    /// `/` as `\/`.
    private static func unescaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\\/", with: "/")
    }
}

/// The header's own moment format: local time with an offset, seconds and
/// hundredths.
private nonisolated let reportStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SS Z"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// What a Windows minidump says about itself without being opened.
///
/// A `.dmp` is a process image: every thread's stack, and often the heap. It
/// is bytes nobody can read out of a report, it can be hundreds of megabytes,
/// and it carries whatever the game had in memory — so level 0 and level 1
/// keep its size and the modules that were loaded, which is the part that
/// answers "which DLL was it in", and nothing else.
///
/// The format is a header, a directory of streams, and the streams; the module
/// list (stream type 4) names every DLL with a UTF-16 string at its own offset.
nonisolated struct MinidumpMetadata: Sendable, Equatable {
    let bytes: Int
    /// The modules that were loaded, in the order the dump lists them.
    let modules: [String]

    /// The dump's own account of itself, or `nil` for a file that is not one.
    static func read(_ url: URL) -> MinidumpMetadata? {
        guard let data = try? Data(contentsOf: url), data.count >= headerBytes,
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

    /// The module list: a count, then one fixed-size record per module whose
    /// fifth field is the offset of its name.
    private static func modules(in data: Data, at offset: Int) -> [String] {
        guard let count = data.integer(UInt32.self, at: offset) else { return [] }
        var found: [String] = []
        for index in 0 ..< min(Int(count), maximumModules) {
            let record = offset + 4 + index * moduleRecordBytes
            guard let nameOffset = data.integer(UInt32.self, at: record + moduleNameField),
                  let name = string(in: data, at: Int(nameOffset)) else { continue }
            // A Windows path, so the last component is after a backslash —
            // which `NSString.lastPathComponent` does not know about.
            found.append(
                name.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init)
                    ?? name,
            )
        }
        return found
    }

    /// A minidump string: a byte length, then that many bytes of UTF-16.
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

    /// One line for a report: how large it is and what was in it.
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
    private static let moduleNameField = 24
    private static let moduleListStream: UInt32 = 4
    private static let maximumStreams = 64
    private static let maximumModules = 512
    private static let maximumStringBytes: UInt32 = 4096
}

private nonisolated extension Data {
    /// A little-endian integer at a byte offset from the start, or `nil` when
    /// the file ends before it.
    func integer<Value: FixedWidthInteger>(_: Value.Type, at offset: Int) -> Value? {
        let start = startIndex + offset
        let end = start + MemoryLayout<Value>.size
        guard offset >= 0, end <= endIndex else { return nil }
        return self[start ..< end].reversed().reduce(Value.zero) { $0 << 8 | Value($1) }
    }
}
