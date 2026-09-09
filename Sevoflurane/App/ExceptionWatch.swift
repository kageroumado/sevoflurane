import AppKit
import Foundation
import ObjectiveC

/// The preprocessor already installed by another library, if any. A C function
/// pointer cannot capture, so the chain lives at file scope.
///
/// Both globals are file-scope rather than static members of ``ExceptionWatch``
/// because Swift 6.3.3's `SendNonSendable` SIL pass crashes on a
/// `@convention(c)` closure assigned to a static member of a type in a module
/// that defaults to `@MainActor`.
private nonisolated(unsafe) var chainedPreprocessor: (@convention(c) (Any) -> Any)?

/// Guards against a throw raised *by* the reporting itself, which would
/// otherwise recurse until the stack ran out.
private nonisolated(unsafe) var isReporting = false

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

    /// Where a sidecar lands: beside the log file, one file per throw, named
    /// so `sevo diag` can pick up every one of them.
    static func fileURL(at date: Date) -> URL {
        EventLog.fileURL
            .deletingLastPathComponent()
            .appending(path: "Sevoflurane-exception-\(Int(date.timeIntervalSince1970)).json")
    }
}

private nonisolated func reportThrow(_ exception: Any) {
    guard !isReporting else { return }
    isReporting = true
    defer { isReporting = false }
    let now = Date()
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

    var lines = ["ObjC exception thrown on \(thread) — \(name): \(reason)"]
    lines.append("    key window: \(window ?? "none")")
    lines += stack.prefix(ExceptionWatch.loggedFrames).map { "    \($0)" }
    if let sidecar = write(report, at: now) {
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

/// Writes the sidecar, returning where it landed. Synchronous, like the log
/// lines: the throw resumes into a trap that ends the process.
private nonisolated func write(_ report: ExceptionReport, at date: Date) -> URL? {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(report) else { return nil }
    let url = ExceptionReport.fileURL(at: date)
    guard (try? data.write(to: url)) != nil else { return nil }
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
