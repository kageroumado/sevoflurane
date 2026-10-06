import Foundation
import os

/// Runs one store client command: its standard output kept whole for the
/// JSON a command prints, every line of either stream handed over as it
/// arrives for the progress a download logs.
///
/// Cancelling the calling task interrupts the client the way Control-C
/// would, which both clients answer by saving where a download had got to,
/// and kills it if it is still there ``interruptGrace`` later.
nonisolated enum StoreProcess {
    struct Result: Sendable {
        let status: Int32
        let stdout: String
        let stderr: String

        var succeeded: Bool {
            status == 0
        }

        /// The client's own last word on a failure: the last error line it
        /// logged, else the last line of either stream.
        var failure: String {
            let lines = (stderr + "\n" + stdout).split(whereSeparator: \.isNewline).map(String.init)
            let errors = lines.filter { $0.contains("ERROR:") || $0.contains("CRITICAL:") || $0.contains("FATAL:") }
            let line = errors.last ?? lines.last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            return line.map(StoreOutput.stripLogPrefix) ?? "exited with status \(status)"
        }
    }

    static let interruptGrace: Duration = .seconds(10)

    /// Runs `tool` with `arguments` to its end, or until `timeout`.
    @concurrent
    static func run(
        _ tool: StoreTool,
        _ arguments: [String],
        timeout: Duration? = nil,
        onLine: (@Sendable (String) -> Void)? = nil,
    ) async throws -> Result {
        guard tool.isInstalled else {
            throw StoreFailure("\(tool.rawValue) is not downloaded yet")
        }
        let process = Process()
        process.executableURL = tool.executable
        process.arguments = tool.leadingArguments + arguments
        process.environment = tool.environment
        process.standardInput = FileHandle.nullDevice
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let stdout = LineCollector(onLine: onLine)
        let stderr = LineCollector(onLine: onLine)
        out.fileHandleForReading.readabilityHandler = { stdout.take($0.availableData) }
        err.fileHandleForReading.readabilityHandler = { stderr.take($0.availableData) }

        try Task.checkCancellation()
        let child = Child()
        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Int32, any Error>) in
                process.terminationHandler = { ended in
                    child.ended()
                    continuation.resume(returning: ended.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                    return
                }
                child.started(process.processIdentifier)
                if let timeout {
                    Task.detached {
                        try? await Task.sleep(for: timeout)
                        child.signal(SIGKILL)
                    }
                }
            }
        } onCancel: {
            child.signal(SIGINT)
            Task.detached {
                try? await Task.sleep(for: interruptGrace)
                child.signal(SIGKILL)
            }
        }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        stdout.take(out.fileHandleForReading.readDataToEndOfFile())
        stderr.take(err.fileHandleForReading.readDataToEndOfFile())
        try Task.checkCancellation()
        return Result(status: status, stdout: stdout.finish(), stderr: stderr.finish())
    }
}

/// The running client's pid, signaled only while it has not been reaped, so
/// a late signal never lands on a process that inherited the number.
private final nonisolated class Child: Sendable {
    private struct State {
        var pid: pid_t?
        var ended = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func started(_ pid: pid_t) {
        state.withLock { $0.pid = pid }
    }

    func ended() {
        state.withLock { $0.ended = true }
    }

    func signal(_ signal: Int32) {
        state.withLock { state in
            guard let pid = state.pid, !state.ended else { return }
            kill(pid, signal)
        }
    }
}

/// A stream's text, whole and as lines. A line ends at a newline or at a
/// carriage return, which is how a client redraws a progress line in place.
private final nonisolated class LineCollector: Sendable {
    private struct State {
        var data = Data()
        var pending = Data()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    func take(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = state.withLock { state in
            state.data.append(chunk)
            state.pending.append(chunk)
            var lines: [String] = []
            while let end = state.pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = state.pending[state.pending.startIndex ..< end]
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
                state.pending = Data(state.pending[state.pending.index(after: end)...])
            }
            return lines
        }
        if let onLine { lines.forEach(onLine) }
    }

    func finish() -> String {
        let (text, rest) = state.withLock { state in
            let rest = state.pending
            state.pending = Data()
            return (String(decoding: state.data, as: UTF8.self), rest)
        }
        if let onLine, !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
        return text
    }
}
