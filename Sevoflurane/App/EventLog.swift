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
        case menu
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
        // Window transitions are write-through: they are the lines that say
        // what the app was showing, they are the last thing written before a
        // crash or a kill, and there are few enough of them that the disk's
        // answer is not a cost anyone can see.
        Self.file.append(
            Self.line(category, message, at: entry.date),
            synchronously: category == .window || Self.flushMode == .synchronous,
        )
        Self.mirror?(category, message, entry.date)
    }

    /// Where a second process sends its lines. The daemon points this at the
    /// app link, so the trail the menu-bar extra and the log window show is
    /// the whole story and not just the half written in this process.
    nonisolated(unsafe) static var mirror: ((Category, String, Date) -> Void)?

    /// One line another process wrote, taken into this process's trail. The
    /// file already has it — the writer appended it there — so this is the
    /// in-memory half only.
    func ingest(_ category: Category, _ message: String, at date: Date) {
        let entry = Entry(id: nextID, date: date, category: category, message: message)
        nextID += 1
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
    }

    /// Whether a line is on disk before the call that wrote it returns.
    ///
    /// A synchronous write costs the caller the disk's answer — tens of
    /// milliseconds while a game installs — so it is not the default. A
    /// Debug mode that wants every line to survive whatever happens next
    /// turns it on for the whole app.
    enum FlushMode {
        case asynchronous
        case synchronous
    }

    /// Written and read on the main actor: the debug switch sets it, `log`
    /// reads it.
    nonisolated(unsafe) static var flushMode: FlushMode = .asynchronous

    /// Blocks until every line written so far is on disk. The quit path and
    /// the exception path call it: both are moments where nothing is left to
    /// drain the queue.
    nonisolated static func flush() {
        file.flush()
    }

    /// Appends text that is on disk before this returns, in the queue's own
    /// order behind whatever is already waiting. The exception path writes
    /// through it rather than opening a second handle, which would seek to
    /// an end the queue is still moving.
    nonisolated static func writeThrough(_ text: String) {
        file.append(text, synchronously: true)
    }

    private static let recentLimit = 100

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let logger = Logger(
        subsystem: "glass.kagerou.sevoflurane", category: "events",
    )
    private nonisolated static let file = LogFile(url: fileURL)

    /// The only way a line reaches the log file: one timestamp, one format,
    /// local time, newline included. Every writer goes through it — the
    /// queued path here and the exception path in ``ExceptionWatch`` — so a
    /// reader can sort the file by time and a grep for a moment finds
    /// everything that happened in it.
    nonisolated static func line(
        _ category: Category, _ message: String, at date: Date = .now,
    ) -> String {
        "\(stamp(date)) [\(category.rawValue)] \(message)\n"
    }

    /// The log's moment format, for the places that carry a time without
    /// being a line — the exception sidecar's own field.
    nonisolated static func stamp(_ date: Date = .now) -> String {
        eventStamp.string(from: date)
    }
}

/// At file scope so both writers share it. `DateFormatter.string(from:)` is
/// thread-safe for a formatter that is never mutated after construction,
/// which is what this is.
private nonisolated let eventStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// The on-disk log, written from a utility queue. A `write(2)` waits on the
/// disk, and while a game installs or the compressor swaps, the disk answers
/// in tens of milliseconds — on the main thread every log line would be a
/// UI stall of that length.
private final nonisolated class LogFile: Sendable {
    /// Rotation threshold, the cap the diagnostics plan gives this trail. One
    /// boot's worth of transitions is a few KB; a debug-mode session writing a
    /// window inventory per adoption, or a level-two run writing the machine's
    /// state every ten seconds, is the case this bounds.
    private static let rotateOverBytes = 10_000_000
    /// How much is written between size checks: a `stat` per line would cost
    /// more than the write it guards.
    private static let checkSizeEveryBytes = 64_000

    private let url: URL
    private let queue: DispatchQueue
    /// Confined to `queue`.
    private nonisolated(unsafe) var handle: FileHandle?
    /// Confined to `queue`: bytes written since the last size check.
    private nonisolated(unsafe) var sinceSizeCheck = 0

    init(url: URL) {
        self.url = url
        queue = DispatchQueue(label: "sevo.eventlog.file", qos: .utility)
    }

    func append(_ line: String, synchronously: Bool) {
        let write: @Sendable () -> Void = { [self] in
            if handle == nil { openFile() }
            let data = Data(line.utf8)
            try? handle?.write(contentsOf: data)
            sinceSizeCheck += data.count
            if sinceSizeCheck > Self.checkSizeEveryBytes {
                sinceSizeCheck = 0
                rotateIfLarge()
            }
        }
        if synchronously {
            queue.sync(execute: write)
        } else {
            queue.async(execute: write)
        }
    }

    /// Moves the trail aside by copy and truncate rather than by renaming:
    /// the handle stays open on the same inode, so a rename would leave every
    /// subsequent line in a file nobody is reading. Runs on `queue`.
    private func rotateIfLarge() {
        let manager = FileManager.default
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > Self.rotateOverBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? manager.removeItem(at: old)
        try? manager.copyItem(at: url, to: old)
        try? handle?.truncate(atOffset: 0)
    }

    /// Returns once the queue has run everything enqueued before the call:
    /// the queue is serial, so an empty block behind them is the wait.
    func flush() {
        queue.sync {}
    }

    private func openFile() {
        let manager = FileManager.default
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
