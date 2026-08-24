import Foundation

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

    @discardableResult
    static func run(
        _ path: String,
        _ arguments: [String],
        environment: [String: String]? = nil,
        capture: Capture = .stdout,
        timeout: Duration = .seconds(20),
    ) async -> (status: Int32?, output: String) {
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
        if let launchError { return (nil, "\(launchError)") }
        var output = ""
        if let pipe, let data = try? pipe.fileHandleForReading.readToEnd() {
            output = String(decoding: data, as: UTF8.self)
        }
        return (process.terminationStatus, output)
    }
}
