import Testing
@testable import Sevoflurane

@MainActor
struct MenuTrackingWatchdogTests {
    private typealias Watchdog = MenuTrackingWatchdog
    private let limit = MenuTrackingWatchdog.stallLimit
    private let escapeDelay = MenuTrackingWatchdog.escapeDelay
    private let stopThreshold = MenuTrackingWatchdog.stopThreshold
    private let abandonThreshold = MenuTrackingWatchdog.abandonThreshold

    @Test
    func `a session shorter than the limit is left alone`() {
        #expect(Watchdog.lever(starvedSeconds: 0, stage: .watching, privateLeverEngages: true) == nil)
        #expect(Watchdog.lever(starvedSeconds: limit - 1, stage: .watching, privateLeverEngages: true) == nil)
    }

    @Test
    func `the limit earns the cancel`() {
        #expect(Watchdog.lever(starvedSeconds: limit, stage: .watching, privateLeverEngages: true) == .cancelled)
    }

    @Test
    func `the escape follows only once the cancel has been given its delay`() {
        #expect(Watchdog.lever(starvedSeconds: limit, stage: .cancelled, privateLeverEngages: true) == nil)
        #expect(Watchdog.lever(
            starvedSeconds: limit + escapeDelay, stage: .cancelled, privateLeverEngages: true,
        ) == .escaped)
    }

    @Test
    func `the stop lever follows only once the escape has been given its delay`() {
        #expect(Watchdog.lever(starvedSeconds: stopThreshold - 1, stage: .escaped, privateLeverEngages: true) == nil)
        #expect(Watchdog.lever(
            starvedSeconds: stopThreshold, stage: .escaped, privateLeverEngages: true,
        ) == .stopped)
    }

    @Test
    func `the escape is the last lever where the private path does not engage`() {
        #expect(Watchdog.lever(starvedSeconds: 600, stage: .escaped, privateLeverEngages: false) == nil)
    }

    @Test
    func `an unrecovered stop lever earns the abandon log after its timeout`() {
        #expect(Watchdog.lever(starvedSeconds: abandonThreshold - 1, stage: .stopped, privateLeverEngages: true) == nil)
        #expect(Watchdog.lever(
            starvedSeconds: abandonThreshold, stage: .stopped, privateLeverEngages: true,
        ) == .abandoned)
    }

    @Test
    func `the stop lever does not escalate to abandon where the private path is off`() {
        #expect(Watchdog.lever(starvedSeconds: 600, stage: .stopped, privateLeverEngages: false) == nil)
    }

    @Test
    func `a session that exhausted every lever is left to the control port`() {
        #expect(Watchdog.lever(starvedSeconds: 600, stage: .abandoned, privateLeverEngages: true) == nil)
    }

    /// The macOS 27 timeline: one menu-bar session, the pointer wandering, and
    /// the starvation only ever growing. Every lever lands on time and in order.
    @Test
    func `on macOS 27 a starving session climbs the whole ladder`() {
        var state = Watchdog.State()
        var levers: [Watchdog.Stage] = []
        for second in stride(from: 1.0, through: 18.0, by: 1.0) {
            let tick = Watchdog.tick(starvedSeconds: second, state: state, privateLeverEngages: true)
            state = tick.state
            #expect(!tick.standDown)
            if let lever = tick.lever {
                levers.append(lever)
            }
        }
        #expect(levers == [.cancelled, .escaped, .stopped, .abandoned])
        #expect(state.isTracking)
        #expect(state.stage == .abandoned)
    }

    /// Where the private lever does not engage — macOS 26, no freeze — the
    /// ladder ends at the Escape however long the session runs.
    @Test
    func `off macOS 27 the ladder ends at the escape`() {
        var state = Watchdog.State()
        var levers: [Watchdog.Stage] = []
        for second in stride(from: 1.0, through: 18.0, by: 1.0) {
            let tick = Watchdog.tick(starvedSeconds: second, state: state, privateLeverEngages: false)
            state = tick.state
            if let lever = tick.lever {
                levers.append(lever)
            }
        }
        #expect(levers == [.cancelled, .escaped])
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
        let opening = Watchdog.tick(starvedSeconds: 1, state: Watchdog.State(), privateLeverEngages: true)
        #expect(!opening.state.isTracking)
        #expect(opening.state.healthyTicks == 1)
        #expect(Watchdog.tick(starvedSeconds: 3, state: opening.state, privateLeverEngages: true).state.isTracking)
    }

    @Test
    func `a starved tick clears the healthy count`() {
        var state = Watchdog.State()
        state.healthyTicks = 2
        #expect(Watchdog.tick(starvedSeconds: 5, state: state, privateLeverEngages: true).state.healthyTicks == 0)
    }

    @Test
    func `the probes stand down after three ticks of a freely running loop`() {
        var state = Watchdog.State()
        state.stage = .stopped
        state.isTracking = true
        var standDowns = 0
        for _ in 1 ... 3 {
            let tick = Watchdog.tick(starvedSeconds: 0.2, state: state, privateLeverEngages: true)
            state = tick.state
            standDowns += tick.standDown ? 1 : 0
        }
        #expect(standDowns == 1)
        #expect(!state.isTracking)
    }

    @Test
    func `the stop outcome reads the same wherever the lever fired`() {
        #expect(
            Watchdog.StopOutcome(sessionSource: "currentSession", enderSent: "endRemoteTracking").summary
                == "found the tracking session via currentSession, sent endRemoteTracking",
        )
        #expect(
            Watchdog.StopOutcome(sessionSource: "menu ‘Help’", enderSent: nil).summary
                == "found the tracking session via menu ‘Help’ but it responded to no ender",
        )
        #expect(
            Watchdog.StopOutcome(sessionSource: nil, enderSent: nil).summary
                == "no tracking session found on the main menu or the open menus",
        )
    }
}
