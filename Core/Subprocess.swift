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
        let pipe = attachStreams(of: process, for: capture)

        // Drained while the process runs rather than read at the end: a tool
        // that fills the pipe's buffer stalls until someone empties it, and
        // wine's descendants inherit the write end and hold it open long
        // after the launcher exits — a read that waits for EOF never returns.
        // Without a pipe there is no end-of-file to wait for.
        let collected = OutputBuffer(reachedEnd: pipe == nil)
        pipe?.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                collected.noteEndOfFile()
                handle.readabilityHandler = nil
            } else {
                collected.append(chunk)
            }
        }

        // Set once Foundation has reaped the child, which is the moment its
        // PID becomes reusable; the watchdog reads it before signaling.
        let exited = OSAllocatedUnfairLock(initialState: false)
        var watchdog: Task<Void, Never>?
        var launchError: (any Error)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in
                exited.withLock { $0 = true }
                continuation.resume()
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    // The check and the signal are two steps: a child reaped
                    // between them, with its PID already handed to a new
                    // process, puts the signal on that process, and a
                    // scheduler pause between the steps makes the window as
                    // wide as the pause. Closing it needs the signaling side
                    // to own reaping, and Foundation.Process reaps in its own
                    // handler.
                    if exited.withLock({ $0 }) { return }
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
        if launchError == nil {
            await collected.waitForEnd(bound: .milliseconds(500))
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let launchError { return (nil, "\(launchError)") }
        return (process.terminationStatus, collected.text)
    }

    /// Points the child's stdout and stderr at the pipe `capture` reads or
    /// at the null device, and returns that pipe when there is one.
    private nonisolated static func attachStreams(of process: Process, for capture: Capture) -> Pipe? {
        switch capture {
        case .stdout:
            let captured = Pipe()
            process.standardOutput = captured
            process.standardError = FileHandle.nullDevice
            return captured
        case .combined:
            let captured = Pipe()
            process.standardOutput = captured
            process.standardError = captured
            return captured
        case .none:
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            return nil
        }
    }
}

/// A subprocess's output, accumulated from readability callbacks — which
/// arrive on Foundation's own queue while the caller waits for the exit.
private final nonisolated class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd: Bool
    /// The one task suspended in ``waitForEnd(bound:)``, held until
    /// end-of-file, cancellation, or the bound takes it — whichever comes
    /// first takes it under the lock, so it resumes exactly once.
    private var waiter: CheckedContinuation<Void, Never>?
    /// Set when cancellation or the bound ends a wait, so a continuation
    /// installed after that moment resumes at once.
    private var waitEnded = false

    init(reachedEnd: Bool) {
        self.reachedEnd = reachedEnd
    }

    func append(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)
    }

    func noteEndOfFile() {
        lock.lock()
        reachedEnd = true
        let resumed = waiter
        waiter = nil
        lock.unlock()
        resumed?.resume()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: data, as: UTF8.self)
    }

    /// Suspends until end-of-file, cancellation of the calling task, or
    /// `bound` elapses. Returns immediately when end-of-file is already seen.
    func waitForEnd(bound: Duration) async {
        if lock.withLock({ reachedEnd }) { return }
        let timer = Task {
            do { try await Task.sleep(for: bound) } catch { return }
            endWait()
        }
        defer { timer.cancel() }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if reachedEnd || waitEnded {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiter = continuation
                lock.unlock()
            }
        } onCancel: {
            endWait()
        }
    }

    private func endWait() {
        lock.lock()
        waitEnded = true
        let resumed = waiter
        waiter = nil
        lock.unlock()
        resumed?.resume()
    }
}
