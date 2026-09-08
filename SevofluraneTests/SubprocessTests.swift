import Foundation
import Testing
@testable import Sevoflurane

/// The one subprocess runner, against real children: the shell for output,
/// `sleep` for the watchdog. Elapsed-time bounds are loose on purpose — they
/// separate a prompt return from a runner that waits on an end-of-file that
/// never comes.
struct SubprocessTests {
    private func timed(
        _ body: () async -> (status: Int32?, output: String),
    ) async -> (result: (status: Int32?, output: String), elapsed: Duration) {
        let began = ContinuousClock.now
        let result = await body()
        return (result, began.duration(to: .now))
    }

    @Test
    func `an uncaptured child returns as soon as it exits`() async {
        let run = await timed { await Subprocess.run("/usr/bin/true", [], capture: .none) }
        #expect(run.result.status == 0)
        #expect(run.result.output.isEmpty)
        #expect(run.elapsed < .milliseconds(300))
    }

    @Test
    func `stdout capture keeps the last line and drops stderr`() async {
        let result = await Subprocess.run(
            "/bin/sh", ["-c", "echo first; echo noise 1>&2; echo last"], capture: .stdout,
        )
        #expect(result.status == 0)
        #expect(result.output == "first\nlast\n")
    }

    @Test
    func `combined capture keeps the last line of both streams`() async {
        let result = await Subprocess.run(
            "/bin/sh", ["-c", "echo out; echo err 1>&2"], capture: .combined,
        )
        #expect(result.status == 0)
        #expect(result.output.contains("out\n"))
        #expect(result.output.hasSuffix("err\n"))
    }

    @Test
    func `a child past its timeout is killed`() async {
        let run = await timed {
            await Subprocess.run("/bin/sleep", ["30"], capture: .none, timeout: .milliseconds(200))
        }
        #expect(run.result.status == SIGKILL)
        #expect(run.elapsed < .seconds(5))
    }

    @Test
    func `a tool that does not exist reports the launch failure`() async {
        let result = await Subprocess.run("/nonexistent/tool", [], capture: .stdout)
        #expect(result.status == nil)
        #expect(!result.output.isEmpty)
    }
}
