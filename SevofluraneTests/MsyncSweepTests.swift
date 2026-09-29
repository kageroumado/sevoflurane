import Foundation
import Testing
@testable import Sevoflurane

/// The report an msync+ wineserver writes for a lost-wake sweep, as the CLI and the
/// supervisor read it.
struct MsyncSweepTests {
    @Test
    func `a sweep that woke a thread names the object and counts it`() throws {
        let text = """
        sevo:msync lost-wake idx=23 type=auto-event low=1 high=0 registered=0 holders=[ 012c:steam.exe 0180:game.exe ]
        sevo:msync lost-wake idx=23 shared with pid=0178 exe=game.exe, dead 1100 ms ago
        sevo:msync sweep objects=434 available=287 lost-wakes=1
        """
        let report = try #require(MsyncSweep.parse(text))
        #expect(report.lostWakes == 1)
        #expect(report.lines.count == 2)
        #expect(report.summary.hasSuffix("lost-wakes=1"))
    }

    @Test
    func `a report the server is still writing reads as none`() {
        #expect(MsyncSweep.parse("sevo:msync lost-wake idx=23 type=auto-event low=1 high=0 registered=0 holders=[ ]\n") == nil)
        #expect(MsyncSweep.parse("") == nil)
    }

    @Test
    func `a quiet sweep reports zero`() throws {
        let report = try #require(MsyncSweep.parse("sevo:msync sweep objects=10 available=4 lost-wakes=0\n"))
        #expect(report.lostWakes == 0)
        #expect(report.lines.isEmpty)
    }
}
