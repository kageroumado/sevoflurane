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

    /// Back to accessory when `closing` was the last window a person can
    /// see. Panels (the popover, Steam's menu mirrors) never count, and
    /// neither do the windows that are ordered in but not on any screen or
    /// at alpha 0: the parked context page, parked toasts, faded menus.
    static func recedeIfLastWindow(closing: NSWindow?) {
        let stillUp = NSApp.windows.contains { window in
            window !== closing && window.isVisible && window.alphaValue > 0
                && !(window is NSPanel) && SteamScreenSpace.isOnSomeScreen(window.frame)
        }
        if !stillUp {
            NSApp.setActivationPolicy(.accessory)
        }
    }
}
