import Testing
@testable import Sevoflurane

@MainActor
struct MenuTrackingWatchdogTests {
    private typealias Watchdog = MenuTrackingWatchdog
    private let limit = MenuTrackingWatchdog.stallLimit
    private let escapeDelay = MenuTrackingWatchdog.escapeDelay

    @Test
    func `a session shorter than the limit is left alone`() {
        #expect(Watchdog.lever(starvedSeconds: 0, stage: .watching) == nil)
        #expect(Watchdog.lever(starvedSeconds: limit - 1, stage: .watching) == nil)
    }

    @Test
    func `the limit earns the cancel`() {
        #expect(Watchdog.lever(starvedSeconds: limit, stage: .watching) == .cancelled)
    }

    @Test
    func `the escape follows only once the cancel has been given its delay`() {
        #expect(Watchdog.lever(starvedSeconds: limit, stage: .cancelled) == nil)
        #expect(Watchdog.lever(starvedSeconds: limit + escapeDelay, stage: .cancelled) == .escaped)
    }

    @Test
    func `a session that survived both levers is left to the control port`() {
        #expect(Watchdog.lever(starvedSeconds: 600, stage: .escaped) == nil)
    }

    /// The retest's timeline: one menu-bar session, four titles, and the
    /// starvation only ever grows. Nothing a title does may reach the state,
    /// so the levers land on time.
    @Test
    func `one starving session earns both levers, whatever the pointer does`() {
        var state = Watchdog.State()
        var levers: [Watchdog.Stage] = []
        for second in stride(from: 1.0, through: 13.0, by: 1.0) {
            let tick = Watchdog.tick(starvedSeconds: second, state: state)
            state = tick.state
            #expect(!tick.standDown)
            if let lever = tick.lever {
                levers.append(lever)
            }
        }
        #expect(levers == [.cancelled, .escaped])
        #expect(state.isTracking)
        #expect(state.stage == .escaped)
    }

    /// A title the pointer crosses inside a live session is not a new
    /// session: re-baselining the clock on it is what let four titles' worth
    /// of a stuck session read as an app with nothing open.
    @Test
    func `a menu opening inside a live session does not start a second clock`() {
        let watchdog = Watchdog()
        #expect(!watchdog.isTimingSession)
        watchdog.menuOpened()
        #expect(watchdog.isTimingSession)
        watchdog.menuOpened()
        #expect(watchdog.isTimingSession)
    }

    @Test
    func `the first ticks of a session read as an app with nothing open`() {
        let opening = Watchdog.tick(starvedSeconds: 1, state: Watchdog.State())
        #expect(!opening.state.isTracking)
        #expect(opening.state.healthyTicks == 1)
        #expect(Watchdog.tick(starvedSeconds: 3, state: opening.state).state.isTracking)
    }

    @Test
    func `a starved tick clears the healthy count`() {
        var state = Watchdog.State()
        state.healthyTicks = 2
        #expect(Watchdog.tick(starvedSeconds: 5, state: state).state.healthyTicks == 0)
    }

    @Test
    func `the probes stand down after three ticks of a freely running loop`() {
        var state = Watchdog.State()
        state.stage = .escaped
        state.isTracking = true
        var standDowns = 0
        for _ in 1 ... 3 {
            let tick = Watchdog.tick(starvedSeconds: 0.2, state: state)
            state = tick.state
            standDowns += tick.standDown ? 1 : 0
        }
        #expect(standDowns == 1)
        #expect(!state.isTracking)
    }
}
