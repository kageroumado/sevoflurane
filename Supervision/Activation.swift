import AppKit

/// The AppKit calls an activation makes, behind a protocol so tests can check
/// their order against a recording double.
@MainActor
protocol ActivationSurface {
    var appIsActive: Bool { get }
    var appPolicy: NSApplication.ActivationPolicy { get }
    /// The process the window server currently has in front.
    var frontmostPID: pid_t? { get }
    func isRunning(_ pid: pid_t) -> Bool
    func promoteToRegular()
    func activateSelf()
    /// Orders every window of this app in front, which is what an activation
    /// the window server accepted still needs to bring the whole app up.
    func activateSelfWithAllWindows()
    /// Returns once the run loop has turned.
    func turnRunLoop() async
    func yieldActivation(to pid: pid_t)
    func activate(pid: pid_t) -> Bool
    func wait(_ duration: Duration) async
    func log(_ line: String)
}

/// Brings a foreign process, or this app's windows, to the front.
///
/// Since macOS 14 an app may activate another only while it holds the
/// activation right, which an `.accessory` app with a non-activating panel
/// lacks. So the right is taken while the user's click grants it, yielded to
/// the target, then spent; the retry budget covers a game that replaces its
/// first window.
@MainActor
struct Activation {
    /// How long the yield-and-activate pair is retried before giving up.
    private static let retryBudgetMilliseconds = 5_000
    private static let retryEveryMilliseconds = 500

    static let retryBudget = Duration.milliseconds(retryBudgetMilliseconds)
    static let retryEvery = Duration.milliseconds(retryEveryMilliseconds)

    /// One attempt, plus a retry every ``retryEvery`` for ``retryBudget``.
    static let attemptLimit = 1 + retryBudgetMilliseconds / retryEveryMilliseconds

    /// Declined attempts in a row, with the same foreign process in front,
    /// that end the retries: the user is staying in that app.
    static let declinedStreakLimit = 3

    private let surface: any ActivationSurface

    init(surface: any ActivationSurface = SystemActivation()) {
        self.surface = surface
    }

    /// Takes the activation right for this app while a user action is still
    /// the reason for it, so a launch that only produces a window seconds
    /// later still has something to spend.
    ///
    /// - Returns: whether this call is what made the app active.
    @discardableResult
    func claimRight() -> Bool {
        guard !surface.appIsActive else { return false }
        if surface.appPolicy != .regular { surface.promoteToRegular() }
        surface.activateSelf()
        return true
    }

    /// Brings this app's windows forward; the all-windows call backs up
    /// `activateSelf()`, which is declined from a menu-bar popover.
    func bringAppForward() {
        if surface.appPolicy != .regular { surface.promoteToRegular() }
        surface.activateSelf()
        surface.activateSelfWithAllWindows()
    }

    /// Brings `pid` to the front.
    ///
    /// - Parameter subject: how the target is named in the log.
    /// - Returns: whether `pid` is frontmost when this returns. `false` comes
    ///   early when a foreign process keeps the front through
    ///   ``declinedStreakLimit`` declined attempts.
    @discardableResult
    func bringForward(pid: pid_t, describedAs subject: String) async -> Bool {
        guard surface.isRunning(pid) else {
            surface.log("\(subject): pid \(pid) has no app to activate")
            return false
        }
        if !surface.appIsActive {
            claimRight()
            // A promotion out of `.accessory` only takes effect once the run
            // loop turns; activating in the same pass is swallowed.
            await surface.turnRunLoop()
        }
        var heldBy: pid_t?
        var declinedStreak = 0
        for attempt in 1 ... Self.attemptLimit {
            surface.yieldActivation(to: pid)
            let accepted = surface.activate(pid: pid)
            let frontmost = surface.frontmostPID
            surface.log(
                "\(subject): activation attempt \(attempt) — "
                    + "this app \(surface.appIsActive ? "active" : "inactive") as "
                    + "\(Self.name(surface.appPolicy)), activate returned "
                    + "\(accepted), frontmost pid \(frontmost.map(String.init) ?? "none")",
            )
            if frontmost == pid { return true }
            if !accepted, let front = frontmost, front == heldBy {
                declinedStreak += 1
            } else {
                declinedStreak = (accepted || frontmost == nil) ? 0 : 1
            }
            heldBy = frontmost
            if declinedStreak == Self.declinedStreakLimit, let front = frontmost {
                surface.log(
                    "\(subject): giving up — pid \(front) has kept the front through "
                        + "\(declinedStreak) declined attempts",
                )
                return false
            }
            guard attempt < Self.attemptLimit else { break }
            await surface.wait(Self.retryEvery)
        }
        return false
    }

    private static func name(_ policy: NSApplication.ActivationPolicy) -> String {
        switch policy {
        case .regular: "regular"
        case .accessory: "accessory"
        case .prohibited: "prohibited"
        @unknown default: "an unknown policy"
        }
    }
}

/// The window server's answer to ``ActivationSurface``.
@MainActor
struct SystemActivation: ActivationSurface {
    var appIsActive: Bool { NSApp.isActive }
    var appPolicy: NSApplication.ActivationPolicy { NSApp.activationPolicy() }
    var frontmostPID: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }

    func isRunning(_ pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid) != nil
    }

    func promoteToRegular() {
        NSApp.setActivationPolicy(.regular)
    }

    func activateSelf() {
        NSApp.activate()
    }

    func activateSelfWithAllWindows() {
        NSRunningApplication.current.activate(options: [.activateAllWindows])
    }

    func turnRunLoop() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func yieldActivation(to pid: pid_t) {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }
        NSApp.yieldActivation(to: app)
    }

    func activate(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.activate(from: .current, options: [.activateAllWindows])
    }

    func wait(_ duration: Duration) async {
        try? await Task.sleep(for: duration)
    }

    func log(_ line: String) {
        EventLog.shared.log(.window, line)
    }
}
