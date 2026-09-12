import AppKit

/// Ends a menu-bar tracking session that has stopped ending on its own.
///
/// Opening a menu bar title runs a nested event loop inside
/// `-[NSMenuTrackingSession startRunningMenuEventLoop:]`, in
/// `NSEventTrackingRunLoopMode`. Main-queue blocks and `.common`-modes timers
/// are still serviced there — a sampled freeze shows the app draining them at
/// 0% CPU while the session refuses to end — so main-queue latency says
/// nothing about it. A `.default`-mode timer is not serviced, and the gap
/// between the two probes is therefore the length of the session.
///
/// What the probes measure is the **session**, not the menu: one session
/// covers every title the pointer crosses, and the run loop is the only thing
/// that can say so, since `menuDidClose` arrives for a menu the menu bar goes
/// on tracking. The clock therefore starts at the first menu of a session and
/// a later title inside it changes nothing — neither the clock nor the levers
/// already pulled.
///
/// The one thing this can honestly report is that the default mode has been
/// starved for longer than two probe intervals. A session that began within
/// the last two intervals reads exactly like an idle app, so ``isTracking``
/// is an observation — for the log, and for the levers below — and never a
/// gate another type's correctness rests on.
///
/// Past ``stallLimit`` the session is taken as stuck and broken from inside.
/// The levers, in order: `cancelTrackingWithoutAnimation()` on the *main*
/// menu, then a synthetic Escape, which the session's `nextEventMatchingMask:`
/// loop takes. A menu the user has deliberately left open for that long is
/// closed under them, which is the price of not leaving the app frozen.
/// Where the menu bar is another process, both levers can be swallowed by it:
/// they are worth pulling, and they are not a recovery anything may assume.
@MainActor
final class MenuTrackingWatchdog {
    /// How long a tracking session may hold the default run-loop mode before
    /// it is taken as stuck.
    static let stallLimit: TimeInterval = 10
    /// How long the cancel is given to land before the Escape follows it.
    static let escapeDelay: TimeInterval = 2

    private enum Probe {
        static let interval: TimeInterval = 1
        /// Consecutive healthy ticks after which the probes stand down.
        static let healthyTicksBeforeStop = 3
        /// `kVK_Escape`.
        static let escapeKeyCode: UInt16 = 53
    }

    /// How far the levers have been pulled at this session.
    enum Stage {
        case watching
        case cancelled
        case escaped
    }

    /// What the probes know about the session in progress. It is made fresh
    /// when a session's clock starts and carried across every title inside it.
    struct State: Equatable {
        var healthyTicks = 0
        var stage = Stage.watching
        var isTracking = false
    }

    /// What one tick of the `.common`-mode probe concluded.
    struct Tick: Equatable {
        var state: State
        /// The lever this tick earned.
        var lever: Stage?
        /// Whether the default mode has been running freely long enough that
        /// the probes can stand down until the next session.
        var standDown: Bool
    }

    /// One probe tick, as arithmetic: what a session starved for
    /// `starvedSeconds` makes of `state`.
    static func tick(starvedSeconds: Double, state: State) -> Tick {
        var state = state
        guard starvedSeconds > Probe.interval * 2 else {
            state.isTracking = false
            state.healthyTicks += 1
            return Tick(
                state: state,
                lever: nil,
                standDown: state.healthyTicks >= Probe.healthyTicksBeforeStop,
            )
        }
        state.isTracking = true
        state.healthyTicks = 0
        guard let lever = lever(starvedSeconds: starvedSeconds, stage: state.stage) else {
            return Tick(state: state, lever: nil, standDown: false)
        }
        state.stage = lever
        return Tick(state: state, lever: lever, standDown: false)
    }

    /// The lever a session that has starved the default mode for
    /// `starvedSeconds` has earned, given how far it has been pushed already.
    static func lever(starvedSeconds: Double, stage: Stage) -> Stage? {
        switch stage {
        case .watching where starvedSeconds >= stallLimit: .cancelled
        case .cancelled where starvedSeconds >= stallLimit + escapeDelay: .escaped
        default: nil
        }
    }

    /// Whether a nested loop has been holding the default run-loop mode for
    /// longer than two probe intervals. The menu delegate cannot answer this:
    /// `menuDidClose` arrives for a menu the menu-bar agent went on to keep
    /// tracking, so a menu is reported closed while its session is still live.
    var isTracking: Bool {
        state.isTracking
    }

    private var defaultProbe: Timer?
    private var commonProbe: Timer?
    private var lastDefaultTick = ContinuousClock.now
    private var state = State()

    /// Whether a session is being timed. The probes stand down once the
    /// default mode has been running freely again, so armed probes mean the
    /// title the pointer has just crossed into belongs to the session already
    /// on the clock.
    var isTimingSession: Bool {
        commonProbe != nil
    }

    /// Starts watching, from the moment a menu is about to open. A menu
    /// opening inside a session already on the clock leaves that clock, and
    /// the levers already pulled at it, exactly where they are.
    func menuOpened() {
        guard !isTimingSession else { return }
        lastDefaultTick = .now
        state = State()
        let inDefault = Timer(timeInterval: Probe.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.lastDefaultTick = .now }
        }
        RunLoop.main.add(inDefault, forMode: .default)
        defaultProbe = inDefault
        let inCommon = Timer(timeInterval: Probe.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.evaluate() }
        }
        RunLoop.main.add(inCommon, forMode: .common)
        commonProbe = inCommon
    }

    /// Ends every menu-bar tracking session. The submenu a title owns is not
    /// the session's root — cancelling it leaves a menu-bar session running —
    /// so the main menu is the one that has to be told.
    static func cancelMenuBarTracking() {
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
    }

    private func evaluate() {
        let starved = Self.seconds(ContinuousClock.now - lastDefaultTick)
        let tick = Self.tick(starvedSeconds: starved, state: state)
        state = tick.state
        if let lever = tick.lever {
            pull(lever, starvedSeconds: starved)
        }
        if tick.standDown {
            stop()
        }
    }

    private func pull(_ lever: Stage, starvedSeconds: Double) {
        switch lever {
        case .cancelled:
            EventLog.shared.log(
                .menu,
                "a menu has held the run loop for \(Int(starvedSeconds))s — cancelling menu tracking",
            )
            Self.cancelMenuBarTracking()
        case .escaped:
            EventLog.shared.log(
                .menu, "menu tracking outlived the cancel — sending Escape to the stuck menu",
            )
            Self.postEscape()
        case .watching:
            return
        }
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    private static func postEscape() {
        guard let escape = NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false,
            keyCode: Probe.escapeKeyCode,
        ) else { return }
        NSApp.postEvent(escape, atStart: true)
    }

    private func stop() {
        defaultProbe?.invalidate()
        defaultProbe = nil
        commonProbe?.invalidate()
        commonProbe = nil
        state = State()
    }
}
