import Foundation
import Testing
@testable import Sevoflurane

/// How a program's launch reaches the Steam host, from whichever store
/// started it.
@MainActor
struct QuickLaunchStoreTests {
    /// A host that writes the beats down instead of acting on them.
    private final class RecordingReporter: ProgramLaunchReporting {
        var beats: [String] = []

        var open: (appID: Int, ticket: UUID)?

        func beginProgramLaunch(appID: Int) -> UUID? {
            if open?.appID == appID { return nil }
            let ticket = UUID()
            open = (appID, ticket)
            beats.append("pressed \(appID)")
            return ticket
        }

        func programDidStart(appID: Int) { beats.append("started \(appID)") }

        func endProgramLaunch(appID: Int, ticket: UUID?) {
            guard let ticket, open?.appID == appID, open?.ticket == ticket else { return }
            open = nil
            beats.append("ended \(appID)")
        }
    }

    /// A Dock tile's launch used to fall back to a store with no hooks when
    /// the popover was not up yet, and recorded nothing (2026-09-26); every
    /// store is wired through this one initializer now.
    @Test
    func `the hooks tell the host each beat of the program's launch`() {
        let host = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)
        let ticket = hooks.pressed(2_000_000_001)
        hooks.started(2_000_000_001)
        hooks.ended(2_000_000_001, ticket)
        #expect(host.beats == ["pressed 2000000001", "started 2000000001", "ended 2000000001"])
    }

    /// A Dock tile's launch was in flight when the row was pressed again; the
    /// daemon answered the press 409, and its end cleared the first launch's
    /// line, so the window and the frames that followed had no launch to
    /// belong to (review, 2026-09-27).
    @Test
    func `a press made while a launch is under way owns no line and ends none`() {
        let host = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)
        let first = hooks.pressed(2_000_000_001)
        let second = hooks.pressed(2_000_000_001)
        #expect(second == nil)
        hooks.ended(2_000_000_001, second)
        #expect(host.open?.ticket == first)
        hooks.ended(2_000_000_001, first)
        #expect(host.open == nil)
        #expect(host.beats == ["pressed 2000000001", "ended 2000000001"])
    }
}
