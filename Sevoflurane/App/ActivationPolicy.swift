import AppKit

/// The app is `.regular` while any of its real windows is on screen and a
/// menu-bar accessory otherwise. Windows that close route through here
/// instead of dropping the policy outright — the Steam window closing must
/// not take the Dock icon out from under an open Settings window, nor the
/// other way around.
@MainActor
enum ActivationPolicy {
    static func becomeRegular() {
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
    }

    /// How long the Dock tile outlives a promotion made for a window that is
    /// still being built — a request for Steam's window while its page boots.
    static let graceForAPromisedWindow = Duration.seconds(30)

    /// The same for the activation right a launch takes: it is spent on the
    /// game's first window, and shader precompilation or an update make that
    /// minutes. ``GameLaunchWatch`` gives a launch three of them.
    static let graceForALaunch = Duration.seconds(210)

    private static var promisedWindowWatch: Task<Void, Never>?

    /// Becomes `.regular` for a window that does not exist yet, and hands the
    /// tile back if none arrives within `grace`.
    ///
    /// A promotion has to come before the window when the window is what the
    /// promotion is for: cooperative activation needs the user's click as the
    /// reason, and by the time a rebuilt page or a game's first frame arrives
    /// there is no event left to attribute the request to. What the app owes
    /// in return is noticing when the window never comes — a wedged client, a
    /// game that dies before it draws — because nothing else takes the tile
    /// away afterwards.
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
    /// window, and with it the Dock tile that comes with being `.regular`.
    /// A game that dies before it draws leaves both behind, so the tile is
    /// handed back once the launch has had its three minutes.
    static func claimRightForALaunch() {
        becomeRegular(forAWindowWithin: graceForALaunch)
        Activation().claimRight()
    }

    /// Back to accessory when `closing` was the last window a person can
    /// see and use.
    static func recedeIfLastWindow(closing: NSWindow?) {
        if isTheLastWindow(closing: closing, among: NSApp.windows) {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Whether nothing a person can see and use is left once `closing` goes.
    static func isTheLastWindow(closing: NSWindow?, among windows: [NSWindow]) -> Bool {
        !windows.contains { $0 !== closing && keepsTheDockTile($0) }
    }

    /// Whether this window is one whose presence earns the app a Dock tile.
    ///
    /// `NSApp.windows` is every window the app owns, most of which nobody can
    /// point at: the menu-bar status item's own `NSStatusBarWindow` is in the
    /// list and sits on a screen at full alpha, as are the popover and Steam's
    /// menu mirrors, the parked context page and parked toasts, and the menus
    /// that are ordered in at alpha 0. What separates the windows a person
    /// works in from all of those is that they can become main: a status item,
    /// a panel and a borderless parked page never do.
    static func keepsTheDockTile(_ window: NSWindow) -> Bool {
        window.canBecomeMain && window.isVisible && window.alphaValue > 0
            && !(window is NSPanel) && SteamScreenSpace.isOnSomeScreen(window.frame)
    }
}
