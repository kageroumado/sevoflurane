import Foundation
import Testing
@testable import Sevoflurane

/// The one subprocess runner, against real children: the shell for output,
/// `sleep` for the watchdog. Every outcome is read off the exit status rather
/// than off the clock — a runner that waited on an end-of-file that never came
/// would be SIGKILLed by its own watchdog and report that, and a watchdog that
/// never fired would report the child's own clean exit.
struct SubprocessTests {
    @Test
    func `an uncaptured child returns as soon as it exits`() async {
        let result = await Subprocess.run("/usr/bin/true", [], capture: .none, timeout: .seconds(20))
        #expect(result.status == 0)
        #expect(result.output.isEmpty)
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
        let result = await Subprocess.run(
            "/bin/sleep", ["30"], capture: .none, timeout: .milliseconds(200),
        )
        #expect(result.status == SIGKILL)
    }

    @Test
    func `a tool that does not exist reports the launch failure`() async {
        let result = await Subprocess.run("/nonexistent/tool", [], capture: .stdout)
        #expect(result.status == nil)
        #expect(!result.output.isEmpty)
    }
}
