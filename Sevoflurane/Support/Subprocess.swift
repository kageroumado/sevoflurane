import Foundation
import os

/// The one subprocess runner: runs a tool to completion and SIGKILLs it at
/// the deadline. A `nil` status means the process never launched.
///
/// The termination handler is installed before `run()` — a process that
/// exits first never fires a handler installed after the fact, and that
/// lost exit would hang the caller forever.
enum Subprocess {
    /// `capture` controls what comes back as output: `.stdout` for tools
    /// whose output is parsed (pgrep, lsof — stderr noise would corrupt the
    /// parse), `.combined` for tools quoted in error messages (installers,
    /// where the failure text lands on stderr), `.none` for chatty tools
    /// like wine whose output is not worth the pipe-buffer deadlock risk.
    enum Capture {
        case stdout
        case combined
        case none
    }

    /// `@concurrent` because the body blocks: a `nonisolated async` function
    /// runs on the *caller's* executor (SE-0461), so without this every
    /// subprocess the app starts from the main actor — the whole of
    /// provisioning — would freeze the UI until the tool exited.
    @discardableResult
    @concurrent
    static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        capture: Capture = .stdout,
        timeout: Duration = .seconds(20),
    ) async -> (status: Int32?, output: String) {
        let tool = URL(fileURLWithPath: path).lastPathComponent
        let interval = PerfProbe.system.beginInterval(
            "Subprocess", id: PerfProbe.system.makeSignpostID(), "\(tool, privacy: .public)",
        )
        defer { PerfProbe.system.endInterval("Subprocess", interval, "\(tool, privacy: .public)") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe: Pipe?
        switch capture {
        case .stdout:
            let captured = Pipe()
            pipe = captured
            process.standardOutput = captured
            process.standardError = FileHandle.nullDevice
        case .combined:
            let captured = Pipe()
            pipe = captured
            process.standardOutput = captured
            process.standardError = captured
        case .none:
            pipe = nil
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
        }

        // Drained while the process runs rather than read at the end: a tool
        // that fills the pipe's buffer stalls until someone empties it, and
        // wine's descendants inherit the write end and hold it open long
        // after the launcher exits — a read that waits for EOF never returns.
        let collected = OutputBuffer()
        pipe?.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                collected.noteEndOfFile()
                handle.readabilityHandler = nil
            } else {
                collected.append(chunk)
            }
        }

        var watchdog: Task<Void, Never>?
        var launchError: (any Error)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog = Task.detached {
                    try? await Task.sleep(for: timeout)
                    kill(pid, SIGKILL)
                }
            } catch {
                process.terminationHandler = nil
                launchError = error
                continuation.resume()
            }
        }
        watchdog?.cancel()
        // A tool's last words can land after its exit, so the output is only
        // complete at end-of-file — but that waits on every writer, and wine
        // leaves descendants holding the write end for as long as they live.
        // Tools whose output is parsed close it at once; the rest are quoted
        // in error messages, where a missing last line costs nothing.
        for _ in 0 ..< 50 where !collected.isAtEnd {
            try? await Task.sleep(for: .milliseconds(10))
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let launchError { return (nil, "\(launchError)") }
        return (process.terminationStatus, collected.text)
    }
}

/// A subprocess's output, accumulated from readability callbacks — which
/// arrive on Foundation's own queue while the caller waits for the exit.
private final nonisolated class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    private var reachedEnd = false

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func noteEndOfFile() {
        lock.lock()
        defer { lock.unlock() }
        reachedEnd = true
    }

    var isAtEnd: Bool {
        lock.lock()
        defer { lock.unlock() }
        return reachedEnd
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }
}
