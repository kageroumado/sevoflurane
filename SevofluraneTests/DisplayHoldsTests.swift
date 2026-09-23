import Foundation
import Testing
@testable import Sevoflurane

/// Reading the display holds out of the power-assertion table, and saying the ones of ours
/// that outlive every game run once each.
struct DisplayHoldsTests {
    private func entry(type: String, pid: pid_t, onBehalfOf: pid_t? = nil, started: Date) -> [String: Any] {
        var entry: [String: Any] = [
            "AssertType": type, "AssertPID": NSNumber(value: pid), "AssertName": "Wine user input",
            "Process Name": "wine", "AssertStartWhen": started,
        ]
        if let onBehalfOf { entry["AssertionOnBehalfOfPID"] = NSNumber(value: onBehalfOf) }
        return entry
    }

    @Test
    func `only assertions that keep the display awake are holds`() {
        let now = Date.now
        #expect(DisplayHolds.hold(from: entry(type: "PreventUserIdleSystemSleep", pid: 1, started: now), ownRoots: []) == nil)
        #expect(DisplayHolds.hold(from: entry(type: "UserIsActive", pid: 1, started: now), ownRoots: []) != nil)
        #expect(DisplayHolds.hold(from: entry(type: "PreventUserIdleDisplaySleep", pid: 1, started: now), ownRoots: []) != nil)
    }

    @Test
    func `a hold taken on this process's behalf counts against it and is ours`() throws {
        let hold = try #require(DisplayHolds.hold(
            from: entry(type: "PreventUserIdleDisplaySleep", pid: 435, onBehalfOf: getpid(), started: .now), ownRoots: [],
        ))
        #expect(hold.pid == getpid())
        #expect(hold.isOurs)
    }

    @Test
    func `a stale hold of ours is said once while no run is open`() throws {
        let now = Date.now
        let old = try #require(DisplayHolds.hold(
            from: entry(type: "UserIsActive", pid: getpid(), started: now.addingTimeInterval(-600)), ownRoots: [],
        ))
        let young = try #require(DisplayHolds.hold(
            from: entry(type: "UserIsActive", pid: getpid(), started: now.addingTimeInterval(-60)), ownRoots: [],
        ))
        var watch = DisplayHoldWatch()
        #expect(watch.check([old, young], runOpen: true, now: now).isEmpty)
        #expect(watch.check([old, young], runOpen: false, now: now) == [old])
        #expect(watch.check([old, young], runOpen: false, now: now).isEmpty)
        // A run in between: the same hold standing after it counts again.
        _ = watch.check([old], runOpen: true, now: now)
        #expect(watch.check([old], runOpen: false, now: now) == [old])
    }
}
