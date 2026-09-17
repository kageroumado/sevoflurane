import AppKit
import ObjectiveC

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
/// 1. `cancelTrackingWithoutAnimation()` on the *main* menu, which is
///    `-[NSMenuTrackingSession dismissAnimated:NO]` on the current session:
///    the one synchronous end, clearing the loop's flag and posting the
///    wake-up the loop's `nextEventMatchingMask:` needs;
/// 2. where the private path engages (macOS 27), the dismissal repair —
///    see ``repairDismissal(_:)``; elsewhere a synthetic Escape, which the
///    session's event handler turns into an animated dismissal;
/// 3. on macOS 27, ``stopMonitoring(_:)``, the last resort that clears the
///    loop's flag directly and wakes the loop.
///
/// The private levers exist because on macOS 27 the system menu bar became
/// another process (`MenuBarClientCore`). A title's dropdown is still tracked
/// *in this process*, by an `NSCocoaMenuImpl` session the agent's callback
/// opens, and that session's loop exits only when its `_isRunningEventLoop`
/// flag is cleared. Two things clear it: a dismissal's pre-dispatch actions,
/// and `stopMonitoringEvents`. An animated dismissal that never completes —
/// its completion arrives through the very run loop the session is parked in
/// — leaves `_isDismissing` set, and every later dismissal, animated or not,
/// is refused on that guard. The repair does what the stalled completion
/// would have done. If even the last resort fails to free the loop within a
/// further short window, the ``Stage/abandoned`` stage logs a distinct,
/// greppable line so external recovery (daemon-driven relaunch) has something
/// to key on: the in-app UI is frozen with the main thread and cannot help
/// itself.
///
/// A menu the user has deliberately left open for that long is closed under
/// them, which is the price of not leaving the app frozen.
@MainActor
final class MenuTrackingWatchdog {
    /// How long a tracking session may hold the default run-loop mode before
    /// it is taken as stuck.
    static let stallLimit: TimeInterval = 10
    /// How long the cancel is given to land before the dismissal lever follows it.
    static let dismissDelay: TimeInterval = 2
    /// How long the dismissal lever is given before the stop lever follows it.
    static let stopDelay: TimeInterval = 2
    /// How long the stop lever is given to free the loop before the session
    /// is logged as unrecovered for external recovery to act on.
    static let abandonDelay: TimeInterval = 3

    /// Elapsed starvation at which the stop lever is pulled.
    static var stopThreshold: TimeInterval { stallLimit + dismissDelay + stopDelay }
    /// Elapsed starvation at which a still-frozen session is declared
    /// unrecovered.
    static var abandonThreshold: TimeInterval { stopThreshold + abandonDelay }

    /// Whether the private levers engage at all. They run only where the
    /// freeze happens: macOS 27 moved the system menu bar into another
    /// process, where a dismissal can stall on a completion the parked loop
    /// never delivers. On macOS 26 and earlier the session ends on its own and
    /// the ladder stops at the Escape.
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
        /// The session has been told to finish dismissing: the repair on
        /// macOS 27, an Escape elsewhere.
        case dismissed
        /// The session's event monitoring has been stopped outright.
        case stopped
        /// Even the last lever left the loop spinning; the freeze is logged
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
        /// The levers the session accepted, in order, or `nil` when a session
        /// was found but none applied.
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
    /// private levers engage; elsewhere the ladder ends at `.dismissed`.
    static func lever(starvedSeconds: Double, stage: Stage, privateLeverEngages: Bool) -> Stage? {
        switch stage {
        case .watching where starvedSeconds >= stallLimit: .cancelled
        case .cancelled where starvedSeconds >= stallLimit + dismissDelay: .dismissed
        case .dismissed where privateLeverEngages && starvedSeconds >= stopThreshold: .stopped
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

    /// The menus whose private tracking session the levers may reach, besides
    /// the app's main menu. The mirror supplies its open titles here; the
    /// default supplies none.
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

    /// Ends every menu-bar tracking session, synchronously. The submenu a
    /// title owns is not the session's root — cancelling it leaves a menu-bar
    /// session running — so the main menu is the one that has to be told.
    /// The animated `cancelTracking()` is never used here: its completion
    /// arrives through the run loop the stuck session is parked in.
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

    /// The candidate menus the private levers inspect: the app's main menu
    /// first, then the mirror's open titles.
    private func candidateMenus() -> [NSMenu] {
        [NSApp.mainMenu].compactMap { $0 } + trackedMenus()
    }

    private func pull(_ lever: Stage, starvedSeconds: Double) {
        switch lever {
        case .cancelled:
            EventLog.shared.log(
                .menu,
                "a menu has held the run loop for \(Int(starvedSeconds))s — cancelling menu tracking"
                    + (Self.privateLeverEngages ? " (\(Self.sessionDescription()))" : ""),
            )
            Self.cancelMenuBarTracking()
        case .dismissed:
            if Self.privateLeverEngages {
                let outcome = Self.stopPrivateSession(candidateMenus: candidateMenus(), levers: [.repair])
                EventLog.shared.log(
                    .menu,
                    "menu tracking outlived the cancel — repairing the dismissal: \(outcome.summary)",
                )
            } else {
                EventLog.shared.log(
                    .menu, "menu tracking outlived the cancel — sending Escape to the stuck menu",
                )
                Self.postEscape()
            }
        case .stopped:
            let outcome = Self.stopPrivateSession(candidateMenus: candidateMenus(), levers: [.stop])
            EventLog.shared.log(
                .menu,
                "menu tracking outlived cancel and repair after \(Int(starvedSeconds))s — stopping the session's event monitoring: \(outcome.summary)",
            )
        case .abandoned:
            EventLog.shared.log(
                .menu,
                "menu-freeze-unrecovered: no lever freed the run loop after \(Int(starvedSeconds))s (\(Self.sessionDescription())) — the app UI is frozen with the main thread; relaunch may be required",
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

    /// Posts the kind of event the session's own dismissal posts to wake its
    /// `nextEventMatchingMask:`: an AppKit-defined event, which the loop's
    /// mask takes and its handler ignores. The loop exits on the flag the
    /// lever already cleared, not on this event.
    private static func postWakeup() {
        guard let wake = NSEvent.otherEvent(
            with: .appKitDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0,
        ) else { return }
        NSApp.postEvent(wake, atStart: true)
    }

    // MARK: - The private levers

    /// What the private levers can do to a session. Each is a private
    /// `NSMenuTrackingSession` surface reached by `responds(to:)`/`perform`,
    /// so a selector renamed on a future macOS is a logged no-op rather than
    /// a crash — this is a workaround for the macOS 27 out-of-process menu
    /// bar, and the private surface is not a contract Apple keeps stable.
    enum Lever: String, CaseIterable {
        /// `dismissAnimated:NO` — the synchronous end, and what the public
        /// `cancelTrackingWithoutAnimation()` sends.
        case dismiss = "dismissAnimated:NO"
        /// What a stalled animated dismissal's completion would have done:
        /// the pre-dispatch actions (which clear the loop's flag and post the
        /// wake-up), then `_isDismissing` cleared so the session is not stuck
        /// refusing every later dismissal.
        case repair = "_performPreDispatchDismissalActions + isDismissing=NO"
        /// `stopMonitoringEvents` — clears the loop's flag with no restore of
        /// key window or input context, then a posted wake-up.
        case stop = "stopMonitoringEvents + wake"
    }

    /// Reaches the private tracking session and pulls `levers` on it, in
    /// order, skipping a lever the session's state says would be refused.
    ///
    /// It must run where it can break the loop: the caller is the watchdog's
    /// `.common`-mode probe, which fires on the main thread *inside* the
    /// spinning nested loop, the same context the cancel fires from. It is
    /// called directly, never dispatched onto the main queue — a
    /// `DispatchQueue.main.async`/`MainActor.run` would enqueue behind the
    /// blocked main queue and never run during the freeze.
    ///
    /// The session is the class's current session first — the object the
    /// main menu's impl returns — then each candidate menu's own.
    @discardableResult
    static func stopPrivateSession(
        candidateMenus: [NSMenu], levers: [Lever] = Lever.allCases,
    ) -> StopOutcome {
        guard let (source, session) = trackingSessions(candidateMenus: candidateMenus).first else {
            return StopOutcome(sessionSource: nil, enderSent: nil)
        }
        var sent: [String] = []
        for lever in levers where pull(lever, on: session) {
            sent.append(lever.rawValue)
        }
        return StopOutcome(sessionSource: source, enderSent: sent.isEmpty ? nil : sent.joined(separator: ", "))
    }

    /// Sends one lever, answering whether the session took it. `repair` is
    /// only for a session stuck mid-dismissal; on any other it would end a
    /// session that is ending on its own.
    private static func pull(_ lever: Lever, on session: NSObject) -> Bool {
        switch lever {
        case .dismiss:
            guard isDismissing(session) != true else { return false }
            return send(session, "dismissAnimated:", flag: false)
        case .repair:
            guard isDismissing(session) == true else { return false }
            guard send(session, "_performPreDispatchDismissalActions") else { return false }
            setDismissing(session, false)
            return true
        case .stop:
            guard send(session, "stopMonitoringEvents") else { return false }
            postWakeup()
            return true
        }
    }

    // MARK: Reading the session

    /// The session's class and the two flags the levers turn on, for the log
    /// and for `GET /menu/session`.
    static func sessionDescription() -> String {
        guard let session = currentTrackingSession() else { return "no current tracking session" }
        let dismissing = isDismissing(session).map { "\($0)" } ?? "?"
        let running = isRunningEventLoop(session).map { "\($0)" } ?? "?"
        return "\(NSStringFromClass(type(of: session))) isDismissing=\(dismissing) isRunningEventLoop=\(running)"
    }

    /// The menu-bar impl in use and the current session's flags, for the
    /// control port. `outOfProcess` is whether the main menu is mirrored into
    /// the macOS 27 menu-bar agent, which is what the Info.plist key
    /// `NSMenuDisableOutOfProcessMenusDueToIncompatibility` turns off.
    static func diagnostics() -> [String: Any] {
        var result: [String: Any] = [:]
        if let menu = NSApp.mainMenu, let impl = menuImpl(of: menu) {
            let name = NSStringFromClass(type(of: impl))
            result["mainMenuImpl"] = name
            result["outOfProcess"] = name.contains("Remote")
        }
        if let session = currentTrackingSession() {
            result["session"] = [
                "class": NSStringFromClass(type(of: session)),
                "isDismissing": isDismissing(session) as Any,
                "isRunningEventLoop": isRunningEventLoop(session) as Any,
            ] as [String: Any]
        } else {
            result["session"] = NSNull()
        }
        return result
    }

    private static func isDismissing(_ session: NSObject) -> Bool? {
        flag(session, ivar: "_isDismissing", key: "isDismissing")
    }

    private static func isRunningEventLoop(_ session: NSObject) -> Bool? {
        flag(session, ivar: "_isRunningEventLoop", key: "isRunningEventLoop")
    }

    private static func setDismissing(_ session: NSObject, _ value: Bool) {
        guard class_getInstanceVariable(type(of: session), "_isDismissing") != nil else { return }
        session.setValue(value, forKey: "isDismissing")
    }

    /// A BOOL ivar read through key-value coding, only when the ivar exists:
    /// an undefined key raises an Objective-C exception nothing here could
    /// catch.
    private static func flag(_ session: NSObject, ivar: String, key: String) -> Bool? {
        guard class_getInstanceVariable(type(of: session), ivar) != nil else { return nil }
        return (session.value(forKey: key) as? NSNumber)?.boolValue
    }

    // MARK: Finding the session

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

    /// A menu's private impl, through the accessor that does not create one
    /// first, so a menu with no impl is left untouched.
    private static func menuImpl(of menu: NSMenu) -> NSObject? {
        for accessor in ["_menuImplIfExists", "_menuImpl", "_menuImplForCallbacks"] {
            if let impl = perform(menu, accessor) { return impl }
        }
        return nil
    }

    private static func trackingSession(of menu: NSMenu) -> NSObject? {
        guard let impl = menuImpl(of: menu) else { return nil }
        return perform(impl, "trackingSession")
    }

    /// Sends a selector the session responds to, with a `BOOL` argument when
    /// `flag` is given. The return value is discarded without dereferencing,
    /// so a selector that returns `void` or `BOOL` is safe to send.
    private static func send(_ session: NSObject, _ name: String, flag: Bool? = nil) -> Bool {
        let selector = NSSelectorFromString(name)
        guard session.responds(to: selector) else { return false }
        if let flag {
            // `perform(_:with:)` delivers its object argument as the raw
            // pointer, which the callee reads as its BOOL: nil is NO.
            _ = session.perform(selector, with: flag ? session : nil)
        } else {
            _ = session.perform(selector)
        }
        return true
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
        if state.stage == .dismissed || state.stage == .stopped || state.stage == .abandoned {
            EventLog.shared.log(
                .menu,
                "menu levers: the default run-loop mode is running freely again — the stuck menu session ended",
            )
        }
        defaultProbe?.invalidate()
        defaultProbe = nil
        commonProbe?.invalidate()
        commonProbe = nil
        state = State()
    }
}
