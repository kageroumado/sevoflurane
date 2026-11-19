import AppKit
import Foundation
import ObjectiveC
import os

/// The preprocessor another library installed, if any; a C function pointer
/// cannot capture, so the chain lives at file scope. Never move these globals
/// into ``ExceptionWatch``: the `SendNonSendable` SIL pass crashes on a
/// `@convention(c)` closure assigned to a static member in a
/// `@MainActor`-default module.
private nonisolated(unsafe) var chainedPreprocessor: (@convention(c) (Any) -> Any)?

/// Throttles reporting, so a loop that raises on every pass does not write a
/// sidecar and forty log lines per iteration.
private nonisolated let reporting = OSAllocatedUnfairLock(initialState: ExceptionThrottle())

/// Records every Objective-C exception as it is thrown, and passes it on.
///
/// AppKit's event loop swallows exceptions silently, and unwinding out of a
/// Swift concurrency frame skips the pop of the thread-local
/// `ExecutorTrackingInfo`, so the next `@MainActor` isolation check reads a
/// dead stack frame and segfaults, possibly hours later. Returning anything
/// else would hide that damage, so this only records, while the stack still
/// means something: event-log lines and a JSON sidecar with the whole stack and
/// recent activity.
enum ExceptionWatch {
    nonisolated static func install() {
        chainedPreprocessor = objc_setExceptionPreprocessor { exception in
            reportThrow(exception)
            if let chained = chainedPreprocessor { return chained(exception) }
            return exception
        }
    }

    /// Frames of the throwing stack that reach the log file: enough to cross
    /// the Swift/ObjC boundary into the AppKit frames that say which pass
    /// raised (a layout pass and an event handler look alike for twenty
    /// frames). The sidecar carries the rest.
    nonisolated static let loggedFrames = 40

    /// How many sidecars stay beside the log.
    nonisolated static let keptSidecars = 20
}

/// Admits at most ``limit`` reports per ``window``, numbering each sidecar so
/// two throws in one millisecond get a file each.
nonisolated struct ExceptionThrottle {
    static let limit = 10
    static let window: TimeInterval = 60

    private(set) var sequence = 0
    private var admitted: [Date] = []
    /// Throws passed over since the last admitted one.
    private(set) var suppressed = 0

    /// Whether a throw at `date` is written down, with its sidecar's sequence
    /// number and the throws passed over before it.
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
    /// The log's own timestamp format, to line the sidecar up with the log.
    let time: String
    let name: String
    let reason: String
    let thread: String
    /// The key window's title and identifier, which a crash report cannot give.
    let keyWindow: String?
    let stack: [String]
    /// The app's last words before the throw.
    let recent: [String]

    static let filePrefix = "Sevoflurane-exception-"

    /// A sidecar's path: beside the log file, named by millisecond and sequence
    /// number so `sevo diag` picks up every one.
    static func fileURL(at date: Date, sequence: Int) -> URL {
        let milliseconds = Int64(date.timeIntervalSince1970 * 1000)
        return EventLog.fileURL
            .deletingLastPathComponent()
            .appending(path: "\(filePrefix)\(milliseconds)-\(sequence).json")
    }

    /// The sidecar names past the newest `keeping`, oldest first; a name from
    /// the single-number scheme sorts as older.
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

/// Set on a thread while it writes a report, so a throw raised by the reporting
/// returns at once instead of recursing.
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
    // Drops this file's own two frames.
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

/// The key window, read only on the main thread: a background throw has no safe
/// way to ask AppKit.
private nonisolated func keyWindowDescription() -> String? {
    guard Thread.isMainThread, NSApp != nil else { return nil }
    return MainActor.assumeIsolated {
        guard let window = NSApp.keyWindow else { return nil }
        let title = window.title.isEmpty ? "untitled" : window.title
        guard let identifier = window.identifier?.rawValue else { return title }
        return "\(title) (\(identifier))"
    }
}

/// The app's last ten log lines.
private nonisolated func recentMessages() -> [String] {
    guard Thread.isMainThread else { return [] }
    return MainActor.assumeIsolated {
        EventLog.shared.recent.suffix(10).map { "[\($0.category.rawValue)] \($0.message)" }
    }
}

/// Writes the sidecar and prunes past ``ExceptionWatch/keptSidecars``.
/// Synchronous: the throw may resume into a trap that ends the process.
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

/// Writes through ``EventLog``'s file queue synchronously, because the feeding
/// queue is drained by a main-actor task and a main-thread throw usually ends
/// the process before it runs.
private nonisolated func appendToLogFile(_ lines: [String], at date: Date) {
    EventLog.writeThrough(lines.map { EventLog.line(.app, $0, at: date) }.joined())
}
