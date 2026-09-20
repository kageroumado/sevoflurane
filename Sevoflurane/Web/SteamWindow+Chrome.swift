import AppKit
import WebKit

extension SteamWindow {
    /// Where the desktop window's frame is kept between the times it exists.
    static let desktopFrameName = "SteamDesktopWindow"

    /// The per-role window dressing: title bar treatment, background, level,
    /// and visibility behavior.
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
            // Menus stay ordered-in for their whole life, invisible at alpha
            // 0 — see `hide()`. Ordering in at realize time (adoption) means
            // even a menu's first show has no page-visibility gap, and
            // `hidesOnDeactivate` would order out and reopen the gap; Steam
            // dismisses menus on deactivation itself.
            window.hidesOnDeactivate = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        case .keyboard:
            // The keyboard floats over whatever is being typed into and stays
            // up while another app is frontmost.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            webView.underPageBackgroundColor = .clear
        case .gameOverlay:
            // Transparent, floating, click-through, and shown at alpha 0 until
            // the overlay is activated — the page's own dark backdrop is the
            // dimming, so an opaque window would read as solid black. It never
            // hides on deactivation (the game is frontmost while it is up) and
            // joins every Space so it follows a full-screen game.
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
            // A modal over the desktop window: it keeps Steam's own frame and
            // stays up while another app is frontmost, since it may be the
            // last thing the user sees of a quit.
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
        // Steam names its own popups through the document title —
        // "Friends List", or the name of whoever a chat window is with.
        // The page's own header is the title bar (see
        // `SteamWindowRole.hasPopupChrome`), so the macOS one is
        // transparent and titleless; the title is kept for Mission
        // Control and the Window menu.
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
        // Steam draws its own title bar; the macOS one is reduced to the
        // traffic lights floating over it, and Steam's duplicate buttons
        // are hidden by the chrome script.
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.backgroundColor = Self.steamBackground
        window.collectionBehavior.insert(.fullScreenPrimary)
        if role == .desktop {
            window.title = "Steam"
            if !window.setFrameAutosaveName(Self.desktopFrameName) {
                // The name belongs to another `NSWindow` that is still
                // alive — the desktop window is rebuilt on every close and
                // released only by ARC. This one will not remember where
                // the user puts it.
                EventLog.shared.log(
                    .window,
                    "the desktop window could not claim its saved frame: "
                        + "\(Self.desktopFrameName) is held by another window",
                )
            }
            // Steam's strip is 32pt tall; the bare titlebar's ~28pt sets
            // the traffic lights slightly high against Steam's own row. An
            // empty unified-compact toolbar is the supported way to ask
            // for the taller titlebar that centers them.
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
