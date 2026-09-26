import Testing
@testable import Sevoflurane

/// How a program's launch reaches the Steam host, from whichever store
/// started it.
@MainActor
struct QuickLaunchStoreTests {
    /// A host that writes the beats down instead of acting on them.
    private final class RecordingReporter: ProgramLaunchReporting {
        var beats: [String] = []

        func beginProgramLaunch(appID: Int) { beats.append("pressed \(appID)") }
        func programDidStart(appID: Int) { beats.append("started \(appID)") }
        func endProgramLaunch(appID: Int) { beats.append("ended \(appID)") }
    }

    /// A Dock tile's launch used to fall back to a store with no hooks when
    /// the popover was not up yet, and recorded nothing (2026-09-26); every
    /// store is wired through this one initializer now.
    @Test
    func `the hooks tell the host each beat of the program's launch`() {
        let host = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)
        hooks.pressed(2_000_000_001)
        hooks.started(2_000_000_001)
        hooks.ended(2_000_000_001)
        #expect(host.beats == ["pressed 2000000001", "started 2000000001", "ended 2000000001"])
    }
}
