import Foundation

/// What a popup Steam opened is for.
///
/// Steam names every popup it creates, and the name is the only thing that
/// distinguishes the desktop window from a context menu before either has any
/// content: both start as `about:blank` and are filled in by the opener. The
/// names are stable across releases because the popup manager builds them from
/// fixed bases (`SP Desktop`, `contextmenu_<n>`) plus a `_uid<pid>` suffix.
enum SteamWindowRole {
    /// The hidden page that hosts Steam's JavaScript and opens everything else.
    case context
    /// The main desktop window — nav, library, store.
    case desktop
    /// Big Picture Mode. Renders its own top bar with no room for overlaid
    /// traffic lights, so it gets a real title bar outside the content.
    case bigPicture
    /// The first-run login window.
    case login
    /// The on-screen keyboard: a floating panel that must not steal key focus
    /// from whatever is being typed into.
    case keyboard
    /// The controller configurator.
    case controllerConfig
    /// A context menu, root menu, or supernav flyout.
    case menu
    /// The friends list.
    case friends
    /// A chat window — one friend, a group, or several in tabs.
    case chat
    /// One of Steam's own notification toasts. Steam draws these into a
    /// borderless popup of their own, which under CEF is a Windows toast in
    /// the corner of the screen; here they are re-posted through
    /// `UNUserNotificationCenter` and the popup is never shown.
    case toast
    /// The in-game Steam overlay (Shift+Tab), desktop or Big Picture. Steam
    /// opens it as an off-screen composited browser sized to the whole screen;
    /// here it is a transparent, floating, click-through panel placed over the
    /// game and shown only while the overlay is active. Its visibility is
    /// driven by the client's `RegisterForOverlayActivated`, not by the
    /// `ShowWindow` Steam sends at creation.
    case gameOverlay
    /// Steam's generic modal dialog (`PopupWindow_…`): the "Shutting down
    /// Steam" notice, and the confirmations it raises over its main window.
    /// Centered on the desktop window and riding above it as its child, in a
    /// panel that never activates the app — Steam places these against its
    /// own screen model, which lands bottom-left here.
    case dialog
    /// Anything else Steam pops out: game notes, broadcasts, the overlay.
    case auxiliary

    init(popupName: String) {
        // Exact match on the base, or "SP DesktopLoginWindow" would classify
        // as the desktop window by prefix.
        let base = if let range = popupName.range(of: "_uid") {
            String(popupName[..<range.lowerBound])
        } else {
            popupName
        }
        self = switch base {
        case "SP Desktop": .desktop
        case "SP BPM": .bigPicture
        case "SP DesktopLoginWindow": .login
        case "SP Keyboard": .keyboard
        case "SP Controller Configurator": .controllerConfig
        default: Self.byPrefix(base) ?? .auxiliary
        }
    }

    /// Which UI instance opened a popup, from the `_uid<n>` suffix Steam
    /// gives every name: 0 is the desktop UI; a game's overlay UI stamps its
    /// popups with the game's pid (`friendslist_uid2220`), so a friends list
    /// or a game overview with a non-zero uid belongs to that overlay, not to
    /// the desktop, however ordinary its name looks.
    static func instanceUID(ofPopupNamed popupName: String) -> Int {
        guard let range = popupName.range(of: "_uid", options: .backwards) else { return 0 }
        return Int(popupName[range.upperBound...]) ?? 0
    }

    /// The popups Steam names by family rather than by a fixed title: one
    /// per context menu, per chat window, and per notification toast, each
    /// with its own counter or id in the name.
    private static func byPrefix(_ base: String) -> SteamWindowRole? {
        let families: [(prefix: String, role: SteamWindowRole)] = [
            ("contextmenu_", .menu),
            ("friendslist", .friends),
            ("chat_", .chat),
            ("notificationtoasts", .toast),
            ("desktopoverlay", .gameOverlay),
            ("gamepadoverlay", .gameOverlay),
            ("PopupWindow_", .dialog),
        ]
        return families.first { base.hasPrefix($0.prefix) }?.role
    }

    /// Panels never activate the app or take key focus from other apps. The
    /// game overlay is one: it takes key focus itself while active (for its
    /// own input) but must never promote the app to a regular one or steal
    /// focus on Steam's behalf.
    var isPanel: Bool {
        self == .menu || self == .keyboard || self == .gameOverlay || self == .dialog
    }

    /// Whether the window is one of Steam's ordinary popups — friends, chat,
    /// the configurator, notes and the rest — whose page draws a
    /// `.TitleBar.title-area` strip inside a header of its own
    /// (`.titleBarContainer`). These share one treatment: the macOS title bar
    /// is transparent over the page, and the chrome script hides Steam's
    /// strip, pads the header by the title-bar height so its content moves
    /// out from under the traffic lights, and offers the header's remaining
    /// stretch as the drag handle. The header keeps Steam's own color, so the
    /// top of the window matches the rest of it instead of the system's
    /// title-bar material.
    var hasPopupChrome: Bool {
        switch self {
        case .auxiliary, .controllerConfig, .chat, .friends: true
        default: false
        }
    }

    /// Whether this window may ever be put on screen.
    ///
    /// A toast is the one kind that may not: it exists so Steam's own
    /// notification pipeline can render, tick its dismissal timer, and drain
    /// its queue, and it is answered on the Mac side by a real notification
    /// instead. Its page still runs — parked, like the context page.
    var isShowable: Bool {
        self != .toast
    }

    /// Whether WebKit may mark this window's page hidden when the occlusion
    /// service says it is covered — which stops animations, rAF, and the layer
    /// commits behind them.
    ///
    /// On for the windows that are genuinely on screen and can genuinely be
    /// covered: an obscured library should no more animate here than Steam's
    /// own client animates one on Windows. Off for the kinds whose pages
    /// would otherwise never run at all: the context page is parked
    /// off-screen on purpose, a toast is never shown at all and still has a
    /// dismissal timer to tick, and pop-up-level panels report as occluded
    /// even while visible — their pages then never run their fade-ins, and
    /// Steam's menu re-measure loop flickers the window.
    var allowsOcclusionDetection: Bool {
        switch self {
        case .context, .menu, .keyboard, .toast, .gameOverlay: false
        case .desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog: true
        }
    }
}
