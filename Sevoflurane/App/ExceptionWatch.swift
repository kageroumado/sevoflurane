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
/// value is the log line, written where the stack still means something.
enum ExceptionWatch {
    nonisolated static func install() {
        chainedPreprocessor = objc_setExceptionPreprocessor { exception in
            reportThrow(exception)
            if let chained = chainedPreprocessor { return chained(exception) }
            return exception
        }
    }
}

private nonisolated func reportThrow(_ exception: Any) {
    guard !isReporting else { return }
    isReporting = true
    defer { isReporting = false }
    let described = if let exception = exception as? NSException {
        "\(exception.name.rawValue): \(exception.reason ?? "no reason given")"
    } else {
        String(describing: exception)
    }
    let thread = Thread.isMainThread ? "main thread" : "a background thread"
    var lines = ["ObjC exception thrown on \(thread) — \(described)"]
    // The frames below the throw are the whole point; the ones above are this
    // file. Twenty is enough to cross the Swift/ObjC boundary that matters and
    // still fit in something a user can paste into an issue.
    lines += Thread.callStackSymbols.dropFirst(2).prefix(20).map { "    \($0)" }
    appendToLogFile(lines)
}

/// Writes straight to the log file instead of through `EventLog`'s queue.
///
/// That queue is drained by a main-actor task, and the exceptions worth
/// recording are thrown *on* the main thread moments before AppKit ends the
/// process — the queued lines never get written, which is exactly what
/// happened to the first one of these ever caught. These are on disk before
/// the throw resumes.
private nonisolated func appendToLogFile(_ lines: [String]) {
    let stamp = ISO8601DateFormatter()
    stamp.formatOptions = [.withFullDate, .withSpaceBetweenDateAndTime, .withTime]
    let now = stamp.string(from: Date())
    let text = lines.map { "\(now) [app] \($0)\n" }.joined()
    guard let data = text.data(using: .utf8) else { return }
    let url = EventLog.fileURL
    guard let handle = try? FileHandle(forWritingTo: url) else {
        try? data.write(to: url)
        return
    }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data)
}
