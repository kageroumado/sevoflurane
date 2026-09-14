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
/// The levers, in order:
/// 1. `cancelTrackingWithoutAnimation()` on the *main* menu;
/// 2. a synthetic Escape, which the session's `nextEventMatchingMask:` loop
///    takes;
/// 3. on macOS 27+, the private ``stopPrivateSession(candidateMenus:)`` lever,
///    which reaches the tracking session object itself.
///
/// The third lever exists because on macOS 27 the system menu bar became
/// another process (`MenuBarClientCore`). The stuck session lives in that
/// agent, so the in-process cancel — `NSApp.mainMenu.cancelTrackingWithoutAnimation()`,
/// routed through `NSRemoteMenuBarImpl` — reaches nothing that ends it, and
/// the synthetic Escape is swallowed by the remote menu bar. Only by asking
/// the `NSMenuTrackingSession` to end its own event loop does the main thread
/// come back. If even that fails to free the loop within a further short
/// window, the ``Stage/abandoned`` stage logs a distinct, greppable line so
/// external recovery (daemon-driven relaunch) has something to key on: the
/// in-app UI is frozen with the main thread and cannot help itself.
///
/// A menu the user has deliberately left open for that long is closed under
/// them, which is the price of not leaving the app frozen.
@MainActor
final class MenuTrackingWatchdog {
    /// How long a tracking session may hold the default run-loop mode before
    /// it is taken as stuck.
    static let stallLimit: TimeInterval = 10
    /// How long the cancel is given to land before the Escape follows it.
    static let escapeDelay: TimeInterval = 2
    /// How long the Escape is given before the private stop lever follows it.
    static let stopDelay: TimeInterval = 2
    /// How long the private stop lever is given to free the loop before the
    /// session is logged as unrecovered for external recovery to act on.
    static let abandonDelay: TimeInterval = 3

    /// Elapsed starvation at which the private stop lever is pulled.
    static var stopThreshold: TimeInterval { stallLimit + escapeDelay + stopDelay }
    /// Elapsed starvation at which a still-frozen session is declared
    /// unrecovered.
    static var abandonThreshold: TimeInterval { stopThreshold + abandonDelay }

    /// Whether the private stop lever engages at all. It runs only where the
    /// freeze happens: macOS 27 moved the system menu bar into another process,
    /// where the in-process cancel reaches nothing that ends a leaked session.
    /// On macOS 26 and earlier the session ends on its own and the ladder stops
    /// at the Escape.
    static var privateLeverEngages: Bool {
        if #available(macOS 27, *) { true } else { false }
    }

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
        /// The private tracking session has been told to end its event loop.
        case stopped
        /// Even the private lever left the loop spinning; the freeze is logged
        /// for external recovery.
        case abandoned
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

    /// The result of reaching for a private tracking session, for the log.
    struct StopOutcome: Equatable {
        /// Where a session was found, or `nil` when none was.
        var sessionSource: String?
        /// Which ender selector the session accepted, or `nil` when a session
        /// was found but responded to none.
        var enderSent: String?

        /// The log line describing what the lever reached, shared by every
        /// caller so a report reads the same words wherever it fired.
        var summary: String {
            switch (sessionSource, enderSent) {
            case let (source?, ender?):
                "found the tracking session via \(source), sent \(ender)"
            case let (source?, nil):
                "found the tracking session via \(source) but it responded to no ender"
            case (nil, _):
                "no tracking session found on the main menu or the open menus"
            }
        }
    }

    /// One probe tick, as arithmetic: what a session starved for
    /// `starvedSeconds` makes of `state`.
    static func tick(starvedSeconds: Double, state: State, privateLeverEngages: Bool) -> Tick {
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
        guard let lever = lever(
            starvedSeconds: starvedSeconds, stage: state.stage, privateLeverEngages: privateLeverEngages,
        ) else {
            return Tick(state: state, lever: nil, standDown: false)
        }
        state.stage = lever
        return Tick(state: state, lever: lever, standDown: false)
    }

    /// The lever a session that has starved the default mode for
    /// `starvedSeconds` has earned, given how far it has been pushed already.
    /// The `.stopped` and `.abandoned` stages are reached only where the
    /// private lever engages; elsewhere the ladder ends at `.escaped`.
    static func lever(starvedSeconds: Double, stage: Stage, privateLeverEngages: Bool) -> Stage? {
        switch stage {
        case .watching where starvedSeconds >= stallLimit: .cancelled
        case .cancelled where starvedSeconds >= stallLimit + escapeDelay: .escaped
        case .escaped where privateLeverEngages && starvedSeconds >= stopThreshold: .stopped
        case .stopped where privateLeverEngages && starvedSeconds >= abandonThreshold: .abandoned
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

    /// The menus whose private tracking session the stop lever may reach,
    /// besides the app's main menu. The mirror supplies its open titles here;
    /// the default supplies none.
    var trackedMenus: @MainActor () -> [NSMenu] = { [] }

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
        let tick = Self.tick(
            starvedSeconds: starved, state: state, privateLeverEngages: Self.privateLeverEngages,
        )
        state = tick.state
        if let lever = tick.lever {
            pull(lever, starvedSeconds: starved)
        }
        if tick.standDown {
            stop()
        }
    }

    /// The candidate menus the private lever inspects: the app's main menu
    /// first, then the mirror's open titles.
    private func candidateMenus() -> [NSMenu] {
        [NSApp.mainMenu].compactMap { $0 } + trackedMenus()
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
        case .stopped:
            EventLog.shared.log(
                .menu,
                "menu tracking outlived cancel and Escape after \(Int(starvedSeconds))s — reaching the private tracking session",
            )
            let outcome = Self.stopPrivateSession(candidateMenus: candidateMenus())
            EventLog.shared.log(.menu, "private lever: \(outcome.summary)")
            if outcome.enderSent != nil {
                // The main thread is parked in `nextEventMatchingMask:`; the
                // ender set the session's end state but the loop will not
                // re-read it until an event returns from that call. Post one so
                // it wakes, sees the ended session, and returns.
                Self.postWakeup()
            }
        case .abandoned:
            EventLog.shared.log(
                .menu,
                "menu-freeze-unrecovered: the private stop lever did not free the run loop after \(Int(starvedSeconds))s — the system menu bar is still tracking and the app UI is frozen with the main thread; relaunch may be required",
            )
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

    /// Posts a key event only to wake `nextEventMatchingMask:`, whose mask
    /// takes key events; an `applicationDefined` event can fall outside it and
    /// leave the loop asleep. The Escape's dismiss meaning is spent — the loop
    /// exits on the session state the ender already set, not on this key.
    private static func postWakeup() {
        postEscape()
    }

    // MARK: - The private stop lever

    /// Reaches the private `NSMenuTrackingSession` and asks it to end. Every
    /// hop is `responds(to:)`/`perform`, so a selector renamed on a future
    /// macOS is a logged no-op rather than a crash — this is a workaround for
    /// the macOS 27 out-of-process menu bar, whose in-process cancel path
    /// (`NSRemoteMenuBarImpl`) reaches nothing that ends a leaked session, and
    /// the private surface is not a contract Apple keeps stable.
    ///
    /// It must run where it can break the loop: the caller is the watchdog's
    /// `.common`-mode probe, which fires on the main thread *inside* the
    /// spinning nested loop, the same context the cancel and Escape fire from.
    /// It is called directly, never dispatched onto the main queue — a
    /// `DispatchQueue.main.async`/`MainActor.run` would enqueue behind the
    /// blocked main queue and never run during the freeze.
    ///
    /// The session is looked up from the class's current session first, then
    /// from each candidate menu's private impl; the first session that accepts
    /// an ender wins.
    @discardableResult
    static func stopPrivateSession(candidateMenus: [NSMenu]) -> StopOutcome {
        var firstSource: String?
        for (source, session) in trackingSessions(candidateMenus: candidateMenus) {
            firstSource = firstSource ?? source
            if let ender = end(session) {
                return StopOutcome(sessionSource: source, enderSent: ender)
            }
        }
        return StopOutcome(sessionSource: firstSource, enderSent: nil)
    }

    /// Enders tried on a found session, in order. `endRemoteTracking` is the
    /// remote menu bar's own path and takes no argument; the others are a
    /// fallback for a future macOS that renamed it. `stopRunningMenuEventLoop:`
    /// and `dismissAnimated:` take an argument, passed as `nil` (which the
    /// runtime delivers as a zero `BOOL`).
    private static let enders = [
        "endRemoteTracking",
        "stopRunningMenuEventLoop:",
        "dismissAnimated:",
    ]

    /// Every tracking session reachable now, newest source first: the class's
    /// current session, then each candidate menu's impl's session.
    private static func trackingSessions(candidateMenus: [NSMenu]) -> [(String, NSObject)] {
        var found: [(String, NSObject)] = []
        if let current = currentTrackingSession() {
            found.append(("currentSession", current))
        }
        for menu in candidateMenus {
            guard let session = trackingSession(of: menu) else { continue }
            found.append(("menu ‘\(menu.title)’", session))
        }
        return found
    }

    /// `+[NSMenuTrackingSession currentSession]`, reached reflectively.
    private static func currentTrackingSession() -> NSObject? {
        guard let cls = NSClassFromString("NSMenuTrackingSession") else { return nil }
        return perform(cls as AnyObject, "currentSession")
    }

    /// A menu's tracking session, reached through its private impl. The impl
    /// accessor that does not create one is preferred, so a menu with no live
    /// session is left untouched.
    private static func trackingSession(of menu: NSMenu) -> NSObject? {
        for accessor in ["_menuImplIfExists", "_menuImpl", "_menuImplForCallbacks"] {
            guard let impl = perform(menu, accessor) else { continue }
            if let session = perform(impl, "trackingSession") { return session }
        }
        return nil
    }

    /// Sends the first ender the session responds to, answering which. The
    /// return value of the ender is discarded without dereferencing, so a
    /// selector that returns `void` or `BOOL` is safe to send.
    private static func end(_ session: NSObject) -> String? {
        for name in enders {
            let selector = NSSelectorFromString(name)
            guard session.responds(to: selector) else { continue }
            if name.hasSuffix(":") {
                _ = session.perform(selector, with: nil)
            } else {
                _ = session.perform(selector)
            }
            return name
        }
        return nil
    }

    /// Sends a zero-argument getter and returns its object result, or `nil`
    /// when the target does not respond or the getter returned `nil`. The
    /// getters used here (`currentSession`, `_menuImpl*`, `trackingSession`)
    /// are `+0` returns, so the value is taken unretained.
    private static func perform(_ target: AnyObject, _ name: String) -> NSObject? {
        let selector = NSSelectorFromString(name)
        guard target.responds(to: selector) else { return nil }
        let result: Unmanaged<AnyObject>? = target.perform(selector)
        return result?.takeUnretainedValue() as? NSObject
    }

    private func stop() {
        if state.stage == .stopped || state.stage == .abandoned {
            EventLog.shared.log(
                .menu,
                "private lever: the default run-loop mode is running freely again — the stuck menu session ended",
            )
        }
        defaultProbe?.invalidate()
        defaultProbe = nil
        commonProbe?.invalidate()
        commonProbe = nil
        state = State()
    }
}
