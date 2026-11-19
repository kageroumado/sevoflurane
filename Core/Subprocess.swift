import Foundation
import os

/// The one subprocess runner: runs a tool to completion and SIGKILLs it at
/// the deadline. A `nil` status means the process never launched.
///
/// The termination handler must be installed before `run()`: a process that
/// exits first never fires a later handler, and the caller hangs forever.
enum Subprocess {
    /// `.stdout` for tools whose output is parsed (pgrep, lsof), `.combined`
    /// for tools quoted in error messages (installers write failures to
    /// stderr), `.none` for chatty tools like wine.
    enum Capture {
        case stdout
        case combined
        case none
    }

    /// `@concurrent` because the body blocks: a `nonisolated async` function
    /// runs on the caller's executor (SE-0461), so a call from the main actor
    /// would freeze the UI until the tool exited.
    @discardableResult
    @concurrent
    static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        capture: Capture = .stdout,
        timeout: Duration = .seconds(20),
        reapGrace: Duration = .seconds(5),
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

        // Drained while the process runs: a tool that fills the pipe's buffer
        // stalls, and wine's descendants hold the write end open long after
        // the launcher exits, so a read that waits for EOF never returns.
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

        // `exited` is set once Foundation has reaped the child and its PID is
        // reusable. `resumed` lets either the handler or the watchdog resume
        // the continuation once: a child in an uninterruptible kernel wait
        // (`lsof` on a wedged file system) survives `SIGKILL`, and waiting on
        // it would freeze the supervisor.
        let exited = OSAllocatedUnfairLock(initialState: false)
        let resumed = OSAllocatedUnfairLock(initialState: false)
        var watchdog: Task<Void, Never>?
        var launchError: (any Error)?
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let resumeOnce: @Sendable () -> Void = {
                let first = resumed.withLock { already -> Bool in
                    defer { already = true }
                    return !already
                }
                if first { continuation.resume() }
            }
            process.terminationHandler = { _ in
                exited.withLock { $0 = true }
                resumeOnce()
            }
            do {
                try process.run()
                let pid = process.processIdentifier
                watchdog = Task.detached {
                    do { try await Task.sleep(for: timeout) } catch { return }
                    // A known race: a child reaped between this check and
                    // the signal can have its PID reused. Closing it needs the
                    // signaling side to own reaping, which Foundation.Process keeps.
                    if exited.withLock({ $0 }) { return }
                    kill(pid, SIGKILL)
                    do { try await Task.sleep(for: reapGrace) } catch { return }
                    if exited.withLock({ $0 }) { return }
                    resumeOnce()
                }
            } catch {
                process.terminationHandler = nil
                launchError = error
                continuation.resume()
            }
        }
        watchdog?.cancel()
        // Output is complete only at end-of-file, which wine's descendants can
        // hold off indefinitely, so the wait is bounded. Parsed tools close the
        // pipe at once; for the rest a missing last line costs nothing.
        if launchError == nil {
            await collected.waitForEnd(bound: .milliseconds(500))
        }
        pipe?.fileHandleForReading.readabilityHandler = nil
        if let launchError { return (nil, "\(launchError)") }
        guard exited.withLock({ $0 }) else { return (nil, collected.text) }
        return (process.terminationStatus, collected.text)
    }

    /// Returns the pipe `capture` reads, if any.
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

/// A subprocess's output, accumulated from readability callbacks on
/// Foundation's own queue.
private final nonisolated class OutputBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private var reachedEnd: Bool
    /// Taken under the lock by whichever of end-of-file, cancellation or the
    /// bound comes first, so it resumes exactly once.
    private var waiter: CheckedContinuation<Void, Never>?
    /// Lets a continuation installed after cancellation or the bound resume at once.
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

    /// Suspends until end-of-file, cancellation, or `bound` elapses.
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
