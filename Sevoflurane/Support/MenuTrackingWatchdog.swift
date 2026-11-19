import AppKit
import ObjectiveC

/// Ends a menu-bar tracking session that has stopped ending on its own.
///
/// Opening a menu bar title runs a nested event loop in
/// `NSEventTrackingRunLoopMode`, which still services main-queue blocks and
/// `.common`-mode timers, so main-queue latency says nothing about it. A
/// `.default`-mode timer is not serviced, so the gap between the two probes
/// is the length of the session. One session covers every title the pointer
/// crosses (`menuDidClose` arrives for menus still tracked), so the clock
/// starts at a session's first menu and later titles change nothing.
/// ``isTracking`` only says the default mode has been starved for over two
/// probe intervals; never gate correctness on it.
///
/// Past ``stallLimit`` the session is broken from inside, in order:
/// 1. `cancelTrackingWithoutAnimation()` on the main menu, the synchronous
///    `dismissAnimated:NO` on the current session;
/// 2. on macOS 27 the dismissal ``Lever/repair``; elsewhere a synthetic
///    Escape;
/// 3. on macOS 27 ``Lever/stop``, which clears the loop's flag directly.
///
/// On macOS 27 the menu bar is another process (`MenuBarClientCore`), but a
/// dropdown is still tracked in this process by an `NSCocoaMenuImpl` session
/// whose loop exits only when `_isRunningEventLoop` is cleared. An animated
/// dismissal whose completion never arrives (it comes through the parked run
/// loop) leaves `_isDismissing` set, and every later dismissal is refused.
/// If nothing frees the loop, ``Stage/abandoned`` logs the greppable
/// `menu-freeze-unrecovered` line for external recovery. A menu deliberately
/// held open that long is closed under the user.
@MainActor
final class MenuTrackingWatchdog {
    /// How long a tracking session may hold the default run-loop mode before
    /// it is taken as stuck.
    static let stallLimit: TimeInterval = 10
    /// How long the cancel is given to land before the dismissal lever follows it.
    static let dismissDelay: TimeInterval = 2
    /// How long the dismissal lever is given before the stop lever follows it.
    static let stopDelay: TimeInterval = 2
    /// How long the stop lever is given before the session is logged as unrecovered.
    static let abandonDelay: TimeInterval = 3

    /// Elapsed starvation at which the stop lever is pulled.
    static var stopThreshold: TimeInterval { stallLimit + dismissDelay + stopDelay }
    /// Elapsed starvation at which a session is declared unrecovered.
    static var abandonThreshold: TimeInterval { stopThreshold + abandonDelay }

    /// Whether the private levers engage: only on macOS 27, where the freeze
    /// happens. Earlier, the ladder stops at the Escape.
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
        /// The repair on macOS 27, an Escape elsewhere.
        case dismissed
        case stopped
        /// The last lever left the loop spinning; logged for external recovery.
        case abandoned
    }

    /// What the probes know about the session in progress, reset when its clock starts.
    struct State: Equatable {
        var healthyTicks = 0
        var stage = Stage.watching
        var isTracking = false
    }

    /// What one tick of the `.common`-mode probe concluded.
    struct Tick: Equatable {
        var state: State
        var lever: Stage?
        /// Whether the probes can stand down until the next session.
        var standDown: Bool
    }

    /// The result of reaching for a private tracking session, for the log.
    struct StopOutcome: Equatable {
        /// Where a session was found, or `nil` when none was.
        var sessionSource: String?
        /// The levers the session accepted, in order, or `nil` when none applied.
        var enderSent: String?

        /// The log line describing what the lever reached.
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

    /// The next lever a session starved for `starvedSeconds` has earned.
    /// `.stopped` and `.abandoned` need the private levers.
    static func lever(starvedSeconds: Double, stage: Stage, privateLeverEngages: Bool) -> Stage? {
        switch stage {
        case .watching where starvedSeconds >= stallLimit: .cancelled
        case .cancelled where starvedSeconds >= stallLimit + dismissDelay: .dismissed
        case .dismissed where privateLeverEngages && starvedSeconds >= stopThreshold: .stopped
        case .stopped where privateLeverEngages && starvedSeconds >= abandonThreshold: .abandoned
        default: nil
        }
    }

    /// Whether a nested loop has held the default run-loop mode for longer
    /// than two probe intervals.
    var isTracking: Bool {
        state.isTracking
    }

    /// Menus besides the main menu whose session the levers may reach: the
    /// mirror's open titles.
    var trackedMenus: @MainActor () -> [NSMenu] = { [] }

    private var defaultProbe: Timer?
    private var commonProbe: Timer?
    private var lastDefaultTick = ContinuousClock.now
    private var state = State()

    /// Whether a session is being timed: the probes are armed until the
    /// default mode runs freely again.
    var isTimingSession: Bool {
        commonProbe != nil
    }

    /// Starts watching when a menu is about to open, unless a session is
    /// already on the clock.
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

    /// Ends every menu-bar tracking session, synchronously, through the main
    /// menu: cancelling a title's submenu leaves the session running. Never
    /// use the animated `cancelTracking()`: its completion arrives through
    /// the run loop the stuck session is parked in.
    static func cancelMenuBarTracking() {
        NSApp.mainMenu?.cancelTrackingWithoutAnimation()
    }

    private func evaluate() {
        // A modal alert starves the default mode like a stuck menu and no
        // lever ends it, so the clock holds until it closes.
        if NSApp.modalWindow != nil {
            lastDefaultTick = .now
            return
        }
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

    private func candidateMenus() -> [NSMenu] {
        [NSApp.mainMenu].compactMap(\.self) + trackedMenus()
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

    /// Wakes the loop's `nextEventMatchingMask:` with an AppKit-defined event,
    /// as the session's own dismissal does; the loop exits on the flag the
    /// lever already cleared.
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
    /// `NSMenuTrackingSession` selector reached through `responds(to:)` and
    /// `perform`, so a selector renamed on a future macOS is a logged no-op.
    enum Lever: String, CaseIterable {
        /// The synchronous end that `cancelTrackingWithoutAnimation()` sends.
        case dismiss = "dismissAnimated:NO"
        /// What a stalled animated dismissal's completion would have done:
        /// the pre-dispatch actions, then `_isDismissing` cleared.
        case repair = "_performPreDispatchDismissalActions + isDismissing=NO"
        /// Clears the loop's flag with no restore of key window or input
        /// context, then posts a wake-up.
        case stop = "stopMonitoringEvents + wake"
    }

    /// Pulls `levers` in order on the first tracking session found, skipping
    /// one the session's state would refuse. Call it directly from the
    /// `.common`-mode probe inside the nested loop; never dispatch it onto the
    /// main queue, where it would not run during the freeze.
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

    /// Sends one lever, answering whether the session took it. `repair` runs
    /// only on a session stuck mid-dismissal.
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
    /// the macOS 27 menu-bar agent, which the defaults key
    /// `NSMenuDisableOutOfProcessMenusDueToIncompatibility` (set in
    /// `main.swift`) turns off.
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

    /// A BOOL ivar read through KVC, only when the ivar exists: an undefined
    /// key raises an Objective-C exception Swift cannot catch.
    private static func flag(_ session: NSObject, ivar: String, key: String) -> Bool? {
        guard class_getInstanceVariable(type(of: session), ivar) != nil else { return nil }
        return (session.value(forKey: key) as? NSNumber)?.boolValue
    }

    // MARK: Finding the session

    /// Every tracking session reachable now: the class's current session,
    /// then each candidate menu's.
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

    /// A menu's private impl. `_menuImplIfExists` comes first because it
    /// never creates one; the fallbacks may.
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
    /// `flag` is given. The result is never dereferenced, so a `void` or
    /// `BOOL` return is safe.
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

    /// Sends a zero-argument getter and returns its object result. The
    /// getters used here are `+0` returns, so the value is taken unretained.
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
