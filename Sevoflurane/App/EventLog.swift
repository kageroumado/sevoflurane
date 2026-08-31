import Foundation
import Observation
import os

/// The app's event trail: client, bridge, page, and window state transitions,
/// written to a log file testers can send and mirrored into the menu-bar
/// extra. The file is the answer to "the window froze and nothing said why".
@MainActor
@Observable
final class EventLog {
    static let shared = EventLog()

    /// Where Console.app and testers look.
    nonisolated static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Logs/Sevoflurane.log")

    enum Category: String {
        case client
        case bridge
        case page
        case window
        case supervisor
        case setup
        case update
        case app
    }

    struct Entry: Identifiable, Equatable {
        let id: Int
        let date: Date
        let category: Category
        let message: String
    }

    /// The newest entries, most recent last, capped for the menu-bar extra.
    private(set) var recent: [Entry] = []

    var latest: Entry? {
        recent.last
    }

    /// Order-preserving entry point for nonisolated callers (the bridge
    /// actor, subprocess handlers): entries land in the file and in `recent`
    /// in the order they were enqueued. A `Task { @MainActor }` per line
    /// would not guarantee that, and the file's purpose is a chronological
    /// trail. Entries buffer until `shared` starts consuming.
    nonisolated static func enqueue(_ category: Category, _ message: String) {
        pipe.continuation.yield((category, message))
    }

    private nonisolated static let pipe = AsyncStream.makeStream(of: (Category, String).self)

    private init() {
        Task(name: "Event log pipeline") { [weak self] in
            for await (category, message) in Self.pipe.stream {
                self?.log(category, message)
            }
        }
    }

    func log(_ category: Category, _ message: String) {
        logger.log("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        // Mirrored as a signpost event so the app's own trail lines up
        // against CPU and I/O in an Instruments recording.
        PerfProbe.events.emitEvent(
            "Log", "[\(category.rawValue, privacy: .public)] \(message, privacy: .public)",
        )
        let entry = Entry(id: nextID, date: .now, category: category, message: message)
        nextID += 1
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
        let line = "\(stamp.string(from: entry.date)) [\(entry.category.rawValue)] \(entry.message)\n"
        Self.file.append(line)
    }

    private static let recentLimit = 100

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let logger = Logger(
        subsystem: "glass.kagerou.sevoflurane", category: "events",
    )
    @ObservationIgnored private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private nonisolated static let file = LogFile(url: fileURL)
}

/// The on-disk log, written from a utility queue. A `write(2)` waits on the
/// disk, and while a game installs or the compressor swaps, the disk answers
/// in tens of milliseconds — on the main thread every log line would be a
/// UI stall of that length.
private final nonisolated class LogFile: Sendable {
    /// Rotation threshold; one boot's worth of transitions is a few KB, so
    /// this only ever trips after months of unattended running.
    private static let rotateOverBytes = 5_000_000

    private let url: URL
    private let queue: DispatchQueue
    /// Confined to `queue`.
    nonisolated(unsafe) private var handle: FileHandle?

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "sevo.eventlog.file", qos: .utility)
    }

    func append(_ line: String) {
        queue.async { [self] in
            if handle == nil { openFile() }
            try? handle?.write(contentsOf: Data(line.utf8))
        }
    }

    private func openFile() {
        let manager = FileManager.default
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.rotateOverBytes {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        // O_APPEND, not a one-time seek: several processes share this file
        // (the app, a second harness instance, a test run), and a handle
        // whose offset was fixed at open time overwrites whatever the others
        // appended since. The kernel repositions an O_APPEND write to the
        // real end every time.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
