import AppKit
import WebKit

extension SteamWindow {
    /// Where the desktop window's frame is kept between the times it exists.
    static let desktopFrameName = "SteamDesktopWindow"

    /// The per-role title bar, background, level and visibility behavior.
    func applyRoleChrome(to window: NSWindow) {
        switch role {
        case .auxiliary, .controllerConfig, .friends, .chat:
            applyPopupChrome(to: window)
        case .desktop, .login:
            applyDesktopChrome(to: window)
        case .bigPicture:
            window.title = "Big Picture"
            window.backgroundColor = Self.steamBackground
            window.collectionBehavior.insert(.fullScreenPrimary)
        case .menu:
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            webView.underPageBackgroundColor = .clear
            // Menus stay ordered in at alpha 0 for life (see `hide()`);
            // `hidesOnDeactivate` would order them out, and Steam dismisses
            // menus on deactivation itself.
            window.hidesOnDeactivate = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        case .keyboard:
            // Floats over the field being typed into, whatever app is in front.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            webView.underPageBackgroundColor = .clear
        case .gameOverlay:
            // Transparent (the page's backdrop is the dimming), click-through
            // at alpha 0 until activated, and on every Space so it follows a
            // full-screen game.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.fullScreenAuxiliary, .canJoinAllSpaces]
            webView.underPageBackgroundColor = .clear
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        case .dialog:
            // Stays up while another app is in front: it may be the last
            // thing the user sees of a quit.
            window.backgroundColor = Self.steamBackground
            window.hasShadow = true
            window.hidesOnDeactivate = false
        case .context, .toast:
            break
        }
    }

    /// A popup that carries its own header: the macOS title bar is
    /// transparent, and the title follows the page's.
    private func applyPopupChrome(to window: NSWindow) {
        // The page's header is the title bar; the document title ("Friends
        // List", a chat partner's name) is kept for Mission Control and the
        // Window menu.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.title = webView.title ?? "Steam"
        window.backgroundColor = Self.steamBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        titleObservation = webView.observe(\.title) { [weak window] view, _ in
            onMainThread {
                guard let title = view.title, !title.isEmpty else { return }
                window?.title = title
            }
        }
    }

    /// The desktop and sign-in windows, whose title bar Steam draws itself.
    private func applyDesktopChrome(to window: NSWindow) {
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.steamBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        if role == .desktop {
            window.title = "Steam"
            if !window.setFrameAutosaveName(Self.desktopFrameName) {
                // A previous desktop window not yet released still holds the
                // name.
                EventLog.shared.log(
                    .window,
                    "the desktop window could not claim its saved frame: "
                        + "\(Self.desktopFrameName) is held by another window",
                )
            }
            // An empty unified-compact toolbar gives the taller titlebar that
            // centers the traffic lights on Steam's 32pt strip (bare: ~28pt).
            window.toolbar = NSToolbar()
            window.toolbarStyle = .unifiedCompact
        }
    }

    static let steamBackground = NSColor(
        srgbRed: 0.086,
        green: 0.106,
        blue: 0.133,
        alpha: 1,
    )
}
