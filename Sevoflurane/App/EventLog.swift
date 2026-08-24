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
        let entry = Entry(id: nextID, date: .now, category: category, message: message)
        nextID += 1
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
        append(entry)
    }

    private static let recentLimit = 100
    /// Rotation threshold; one boot's worth of transitions is a few KB, so
    /// this only ever trips after months of unattended running.
    private static let rotateOverBytes = 5_000_000

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private var handle: FileHandle?
    @ObservationIgnored private let logger = Logger(
        subsystem: "glass.kagerou.sevoflurane", category: "events",
    )
    @ObservationIgnored private let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private func append(_ entry: Entry) {
        if handle == nil { openFile() }
        let line = "\(stamp.string(from: entry.date)) [\(entry.category.rawValue)] \(entry.message)\n"
        try? handle?.write(contentsOf: Data(line.utf8))
    }

    private func openFile() {
        let manager = FileManager.default
        let url = Self.fileURL
        if let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
           size > Self.rotateOverBytes {
            let old = url.deletingPathExtension().appendingPathExtension("old.log")
            try? manager.removeItem(at: old)
            try? manager.moveItem(at: url, to: old)
        }
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
            )
            manager.createFile(atPath: url.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }
}
