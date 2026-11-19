import Foundation
import Observation
import os

/// The app's event trail: client, bridge, page, and window state transitions,
/// written to a log file testers can send and mirrored into the menu-bar
/// extra.
@MainActor
@Observable
final class EventLog {
    static let shared = EventLog()

    /// The log file; a test host, gallery or simulated boot writes a separate
    /// one, so bug reports hold only the real app's lines.
    nonisolated static let fileURL = AppIdentity.logFile(isSimulatedProcess ? "simulated" : nil)

    private nonisolated static var isSimulatedProcess: Bool {
        let environment = ProcessInfo.processInfo.environment
        return TestHost.isHosting
            || environment["SEVO_GALLERY"] == "1"
            || environment["SEVO_DEMO"] != nil
    }

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

    /// Order-preserving entry point for nonisolated callers; a
    /// `Task { @MainActor }` per line would reorder them. Entries buffer until
    /// `shared` starts consuming.
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
        // Messages name paths, games and devices. The log file is this
        // account's; the unified log is every admin's and every sysdiagnose's,
        // so a release build keeps the text out of it.
        #if DEBUG
            logger.log("[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
            // A signpost too, to line up with Instruments recordings.
            PerfProbe.events.emitEvent(
                "Log", "[\(category.rawValue, privacy: .public)] \(message, privacy: .public)",
            )
        #else
            logger.log("[\(category.rawValue, privacy: .public)] \(message, privacy: .private)")
            PerfProbe.events.emitEvent(
                "Log", "[\(category.rawValue, privacy: .public)] \(message, privacy: .private)",
            )
        #endif
        let entry = Entry(id: nextID, date: .now, category: category, message: message)
        nextID += 1
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
        // Window lines are write-through: the last thing written before a
        // crash, and rare enough to cost nothing.
        Self.file.append(
            Self.line(category, message, at: entry.date),
            synchronously: category == .window || Self.flushMode == .synchronous,
        )
        Self.mirror?(category, message, entry.date)
    }

    /// Where a second process sends its lines; the daemon points it at the app link.
    nonisolated(unsafe) static var mirror: ((Category, String, Date) -> Void)?

    /// Takes in a line another process already wrote to the file.
    func ingest(_ category: Category, _ message: String, at date: Date) {
        let entry = Entry(id: nextID, date: date, category: category, message: message)
        nextID += 1
        recent.append(entry)
        if recent.count > Self.recentLimit {
            recent.removeFirst(recent.count - Self.recentLimit)
        }
    }

    /// Whether a line is on disk before `log` returns. A synchronous write
    /// costs tens of milliseconds while a game installs, so only Debug mode
    /// turns it on.
    enum FlushMode {
        case asynchronous
        case synchronous
    }

    /// Written and read on the main actor: the debug switch sets it, `log`
    /// reads it.
    nonisolated(unsafe) static var flushMode: FlushMode = .asynchronous

    /// Blocks until every line written so far is on disk, for the quit and
    /// exception paths.
    nonisolated static func flush() {
        file.flush()
    }

    /// Appends text synchronously, behind whatever is queued; the exception
    /// path uses it rather than a second handle.
    nonisolated static func writeThrough(_ text: String) {
        file.append(text, synchronously: true)
    }

    private static let recentLimit = 100

    @ObservationIgnored private var nextID = 0
    @ObservationIgnored private let logger = Logger(
        subsystem: "glass.kagerou.sevoflurane", category: "events",
    )
    private nonisolated static let file = LogFile(url: fileURL)

    /// The one line format every writer uses (here and ``ExceptionWatch``):
    /// local timestamp, category, message, newline.
    nonisolated static func line(
        _ category: Category, _ message: String, at date: Date = .now,
    ) -> String {
        "\(stamp(date)) [\(category.rawValue)] \(oneLine(message))\n"
    }

    /// `message` on one line. Messages quote request paths, game names and
    /// program output; a line break in one would forge the entries after it
    /// for whoever reads the log, an agent included.
    nonisolated static func oneLine(_ message: String) -> String {
        guard message.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) else { return message }
        var scalars = String.UnicodeScalarView()
        for scalar in message.unicodeScalars {
            switch scalar.value {
            case 0x0A, 0x0D: scalars.append(contentsOf: " ⏎ ".unicodeScalars)
            case 0x09: scalars.append(" ")
            case 0 ..< 0x20, 0x7F: continue
            default: scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// The log's timestamp format, for the exception sidecar's field.
    nonisolated static func stamp(_ date: Date = .now) -> String {
        eventStamp.string(from: date)
    }
}

/// Shared by both writers; thread-safe because it is never mutated after
/// construction.
private nonisolated let eventStamp: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
    formatter.locale = Locale(identifier: "en_US_POSIX")
    return formatter
}()

/// The on-disk log, written from a utility queue: a `write(2)` can take tens
/// of milliseconds while a game installs.
private final nonisolated class LogFile: Sendable {
    /// Rotation threshold; one boot writes a few KB, debug and level-two runs
    /// far more.
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

    /// Rotates by copy and truncate: a rename would leave the open handle
    /// writing to the moved file. Runs on `queue`.
    private func rotateIfLarge() {
        let manager = FileManager.default
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > Self.rotateOverBytes else { return }
        let old = url.deletingPathExtension().appendingPathExtension("old.log")
        try? manager.removeItem(at: old)
        try? manager.copyItem(at: url, to: old)
        try? handle?.truncate(atOffset: 0)
    }

    /// Returns once the serial queue has run everything enqueued before it.
    func flush() {
        queue.sync {}
    }

    private func openFile() {
        let manager = FileManager.default
        try? manager.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true,
        )
        // O_APPEND: several processes share this file, and a fixed offset
        // would overwrite their lines.
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        guard fd >= 0 else { return }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }
}
