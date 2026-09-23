import AppKit
import Foundation
import ObjectiveC
import os

/// The preprocessor already installed by another library, if any. A C function
/// pointer cannot capture, so the chain lives at file scope.
///
/// Both globals are file-scope rather than static members of ``ExceptionWatch``
/// because the compiler's `SendNonSendable` SIL pass crashes on a
/// `@convention(c)` closure assigned to a static member of a type in a module
/// that defaults to `@MainActor`.
private nonisolated(unsafe) var chainedPreprocessor: (@convention(c) (Any) -> Any)?

/// How many throws have been written, and how many recently: a loop that
/// raises on every pass would otherwise write a sidecar and forty log lines
/// per iteration.
private nonisolated let reporting = OSAllocatedUnfairLock(initialState: ExceptionThrottle())

/// Records every Objective-C exception at the moment it is thrown, and lets it
/// carry on.
///
/// The app raises none of its own, but it hosts Steam's entire UI: a client
/// update can put WebKit, AppKit, or one of Steam's own bridge calls somewhere
/// that raises, and AppKit's event loop swallows it without a word. A swallowed
/// exception is not harmless here — unwinding out of a Swift concurrency frame
/// skips the pop of the thread-local `ExecutorTrackingInfo`, so the next
/// `@MainActor` isolation check to run reads a dead stack frame and segfaults,
/// possibly hours later and with nothing left to say what caused it. That is
/// the crash this exists to explain.
///
/// It deliberately does **not** swallow anything. By the time a preprocessor
/// runs the throw is already in flight and the unwind is going to happen;
/// returning something else would hide the damage rather than prevent it. The
/// value is what it writes while the stack still means something: lines in the
/// event log, and a JSON sidecar carrying the whole stack and what the app had
/// just been doing.
enum ExceptionWatch {
    nonisolated static func install() {
        chainedPreprocessor = objc_setExceptionPreprocessor { exception in
            reportThrow(exception)
            if let chained = chainedPreprocessor { return chained(exception) }
            return exception
        }
    }

    /// How many frames of the throwing stack reach the log file.
    ///
    /// Enough to cross the Swift/ObjC boundary and reach the AppKit frames
    /// that say which pass raised — a layout pass and an event handler look
    /// alike for the first twenty frames — and still fit in something a user
    /// can paste into an issue. The sidecar carries the rest.
    nonisolated static let loggedFrames = 40

    /// How many sidecars stay beside the log; older ones are removed as new
    /// ones land.
    nonisolated static let keptSidecars = 20
}

/// Admits at most ``limit`` reports per ``window``, and numbers each sidecar so
/// two throws in one millisecond still get a file each.
nonisolated struct ExceptionThrottle {
    static let limit = 10
    static let window: TimeInterval = 60

    private(set) var sequence = 0
    private var admitted: [Date] = []
    /// Throws passed over since the last admitted one.
    private(set) var suppressed = 0

    /// Whether a throw at `date` is written down. Answers the sequence number
    /// its sidecar takes and how many throws were passed over before it.
    mutating func admit(at date: Date) -> (sequence: Int, suppressedBefore: Int)? {
        admitted.removeAll { date.timeIntervalSince($0) >= Self.window }
        guard admitted.count < Self.limit else {
            suppressed += 1
            return nil
        }
        admitted.append(date)
        sequence += 1
        defer { suppressed = 0 }
        return (sequence, suppressed)
    }
}

/// One throw, as it is written down.
nonisolated struct ExceptionReport: Codable {
    /// The log's own moment format, so a reader can line the sidecar up
    /// against the log file by eye.
    let time: String
    let name: String
    let reason: String
    let thread: String
    /// The key window's title and identifier — the app's answer to "what was
    /// on screen", which a crash report cannot give.
    let keyWindow: String?
    let stack: [String]
    /// The app's last words before the throw.
    let recent: [String]

    static let filePrefix = "Sevoflurane-exception-"

    /// Where a sidecar lands: beside the log file, one file per throw, named
    /// by the millisecond and the throw's sequence number so `sevo diag` can
    /// pick up every one of them.
    static func fileURL(at date: Date, sequence: Int) -> URL {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        return EventLog.fileURL
            .deletingLastPathComponent()
            .appending(path: "\(filePrefix)\(milliseconds)-\(sequence).json")
    }

    /// The sidecar names past the newest `keeping`, oldest first. Names order
    /// by their numbers; a name from a single-number scheme sorts as older.
    static func staleSidecars(_ names: [String], keeping: Int) -> [String] {
        func key(_ name: String) -> [Int64] {
            name.dropFirst(filePrefix.count).dropLast(".json".count)
                .split(separator: "-").map { Int64($0) ?? 0 }
        }
        let sidecars = names.filter { $0.hasPrefix(filePrefix) && $0.hasSuffix(".json") }
            .sorted { key($0).lexicographicallyPrecedes(key($1)) }
        return Array(sidecars.dropLast(keeping))
    }
}

/// Set on a thread while it writes a report, so a throw raised *by* the
/// reporting returns at once instead of recursing until the stack runs out.
/// Per thread: a throw on another thread at the same moment is its own.
private nonisolated let reportingKey = "glass.kagerou.sevoflurane.reportingException"

private nonisolated func reportThrow(_ exception: Any) {
    let threadState = Thread.current.threadDictionary
    guard threadState[reportingKey] == nil else { return }
    threadState[reportingKey] = true
    defer { threadState.removeObject(forKey: reportingKey) }
    let now = Date()
    guard let admission = reporting.withLock({ $0.admit(at: now) }) else { return }
    let name: String
    let reason: String
    if let exception = exception as? NSException {
        name = exception.name.rawValue
        reason = exception.reason ?? "no reason given"
    } else {
        name = "\(type(of: exception))"
        reason = String(describing: exception)
    }
    let thread = Thread.isMainThread ? "main thread" : "a background thread"
    // The frames below the throw are the whole point; the ones above are this
    // file.
    let stack = Array(Thread.callStackSymbols.dropFirst(2))
    let window = keyWindowDescription()
    let report = ExceptionReport(
        time: EventLog.stamp(now),
        name: name,
        reason: reason,
        thread: thread,
        keyWindow: window,
        stack: stack,
        recent: recentMessages(),
    )

    var lines: [String] = []
    if admission.suppressedBefore > 0 {
        lines.append("\(admission.suppressedBefore) more ObjC exceptions were thrown and not recorded "
            + "(at most \(ExceptionThrottle.limit) a minute are)")
    }
    lines.append("ObjC exception thrown on \(thread) — \(name): \(reason)")
    lines.append("    key window: \(window ?? "none")")
    lines += stack.prefix(ExceptionWatch.loggedFrames).map { "    \($0)" }
    if let sidecar = write(report, at: now, sequence: admission.sequence) {
        lines.append("    full report: \(sidecar.path)")
    }
    appendToLogFile(lines, at: now)
}

/// The window the user was working in. Read only from the main thread: a throw
/// on a background thread has no safe way to ask AppKit anything, and a wrong
/// answer here is worse than none.
private nonisolated func keyWindowDescription() -> String? {
    guard Thread.isMainThread, NSApp != nil else { return nil }
    return MainActor.assumeIsolated {
        guard let window = NSApp.keyWindow else { return nil }
        let title = window.title.isEmpty ? "untitled" : window.title
        guard let identifier = window.identifier?.rawValue else { return title }
        return "\(title) (\(identifier))"
    }
}

/// The app's last ten lines, so the report says what it was doing rather than
/// only where it stopped.
private nonisolated func recentMessages() -> [String] {
    guard Thread.isMainThread else { return [] }
    return MainActor.assumeIsolated {
        EventLog.shared.recent.suffix(10).map { "[\($0.category.rawValue)] \($0.message)" }
    }
}

/// Writes the sidecar and removes the ones past ``ExceptionWatch/keptSidecars``,
/// returning where it landed. Synchronous, like the log lines: the throw may
/// resume into a trap that ends the process, and nothing queued would be
/// written then.
private nonisolated func write(_ report: ExceptionReport, at date: Date, sequence: Int) -> URL? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report) else { return nil }
    let url = ExceptionReport.fileURL(at: date, sequence: sequence)
    guard (try? data.write(to: url)) != nil else { return nil }
    let directory = url.deletingLastPathComponent()
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    for stale in ExceptionReport.staleSidecars(names, keeping: ExceptionWatch.keptSidecars) {
        try? FileManager.default.removeItem(at: directory.appending(path: stale))
    }
    return url
}

/// Writes through ``EventLog``'s own file queue rather than the queue that
/// feeds it.
///
/// That queue is drained by a main-actor task, and the exceptions worth
/// recording are thrown *on* the main thread moments before AppKit ends the
/// process — the queued lines never get written. Going through the file queue
/// synchronously puts everything already waiting on disk first, then these,
/// all before the throw resumes.
private nonisolated func appendToLogFile(_ lines: [String], at date: Date) {
    EventLog.writeThrough(lines.map { EventLog.line(.app, $0, at: date) }.joined())
}
