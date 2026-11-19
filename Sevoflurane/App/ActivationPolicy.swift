import AppKit

/// The app is `.regular` while any of its real windows is on screen and a
/// menu-bar accessory otherwise. Closing windows route through here, so the
/// Steam window closing does not take the Dock icon from an open Settings
/// window.
@MainActor
enum ActivationPolicy {
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// How long the Dock tile outlives a promotion for a window still being
    /// built, such as Steam's while its page boots.
    static let graceForAPromisedWindow = Duration.seconds(30)

    /// The same for a launch's activation right, which waits for the game's
    /// first window: shader precompilation or an update make that minutes.
    static let graceForALaunch = Duration.seconds(210)

    private static var promisedWindowWatch: Task<Void, Never>?

    /// Becomes `.regular` for a window that does not exist yet, and hands the
    /// tile back if none arrives within `grace`.
    ///
    /// The promotion must come first: cooperative activation needs the user's
    /// click as its reason, and by the time a rebuilt page or a game's first
    /// frame arrives no event is left to attribute it to.
    static func becomeRegular(forAWindowWithin grace: Duration) {
        becomeRegular()
        promisedWindowWatch?.cancel()
        promisedWindowWatch = Task(name: "Watch for the promised window") {
            try? await Task.sleep(for: grace)
            guard !Task.isCancelled, NSApp.activationPolicy() == .regular,
                  isTheLastWindow(closing: nil, among: NSApp.windows) else { return }
            EventLog.shared.log(
                .window,
                "no window arrived in \(grace.components.seconds)s — back to the menu bar",
            )
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Takes the activation right a launch will spend on the game's first
    /// window, and the Dock tile with it; the tile goes back once the launch
    /// has had its three minutes.
    static func claimRightForALaunch() {
        becomeRegular(forAWindowWithin: graceForALaunch)
        guard Activation().claimRight() else { return }
        // Read a turn later, when the activation lands. A press in the popover
        // does take the right (measured); it is lost when the user activates
        // another app before the game's window arrives, which is then declined
        // with "this app inactive". This line tells the two apart.
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                let front = NSWorkspace.shared.frontmostApplication
                EventLog.shared.log(
                    .window,
                    "launch pressed — activation right \(NSApp.isActive ? "taken; this app is active" : "not taken within a turn; this app is not yet active")"
                        + ", frontmost \(front?.localizedName ?? "nobody") (pid \(front?.processIdentifier ?? 0))",
                )
            }
        }
    }

    /// Back to accessory when `closing` was the last window a person can use.
    static func recedeIfLastWindow(closing: NSWindow?) {
        if isTheLastWindow(closing: closing, among: NSApp.windows) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Whether nothing a person can use is left once `closing` goes.
    static func isTheLastWindow(closing: NSWindow?, among windows: [NSWindow]) -> Bool {
        !windows.contains { $0 !== closing && keepsTheDockTile($0) }
    }

    /// Whether this window earns the app a Dock tile.
    ///
    /// `NSApp.windows` also holds the status item's `NSStatusBarWindow` at full
    /// alpha, the popover, Steam's menu mirrors, the parked context page and
    /// toasts, and menus at alpha 0. A window a person works in can become
    /// main; those never do.
    static func keepsTheDockTile(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.isVisible && window.alphaValue > 0
            && !(window is NSPanel) && SteamScreenSpace.isOnSomeScreen(window.frame)
    }
}
