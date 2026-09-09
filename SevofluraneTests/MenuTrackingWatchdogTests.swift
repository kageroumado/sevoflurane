import Testing
@testable import Sevoflurane

@MainActor
struct MenuTrackingWatchdogTests {
    private let limit = MenuTrackingWatchdog.stallLimit
    private let escapeDelay = MenuTrackingWatchdog.escapeDelay

    @Test
    func `a session shorter than the limit is left alone`() {
        #expect(MenuTrackingWatchdog.lever(starvedSeconds: 0, stage: .watching) == nil)
        #expect(MenuTrackingWatchdog.lever(starvedSeconds: limit - 1, stage: .watching) == nil)
    }

    @Test
    func `the limit earns the cancel`() {
        #expect(MenuTrackingWatchdog.lever(starvedSeconds: limit, stage: .watching) == .cancelled)
    }

    @Test
    func `the escape follows only once the cancel has been given its delay`() {
        #expect(MenuTrackingWatchdog.lever(starvedSeconds: limit, stage: .cancelled) == nil)
        #expect(
            MenuTrackingWatchdog
                .lever(starvedSeconds: limit + escapeDelay, stage: .cancelled) == .escaped,
        )
    }

    @Test
    func `a session that survived both levers is left to the control port`() {
        #expect(MenuTrackingWatchdog.lever(starvedSeconds: 600, stage: .escaped) == nil)
    }
}
