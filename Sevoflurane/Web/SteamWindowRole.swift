import Foundation

/// What a popup Steam opened is for.
///
/// The popup's name is the only thing that tells the desktop window from a
/// context menu before either has content (both start as `about:blank`). The
/// popup manager builds names from fixed bases (`SP Desktop`,
/// `contextmenu_<n>`) plus a `_uid<pid>` suffix.
nonisolated enum SteamWindowRole {
    /// The hidden page that hosts Steam's JavaScript and opens everything else.
    case context
    /// The main desktop window — nav, library, store.
    case desktop
    /// Big Picture Mode, with a real title bar outside the content.
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
    /// One of Steam's notification toasts: never shown, re-posted through
    /// `UNUserNotificationCenter`.
    case toast
    /// The in-game Steam overlay (Shift+Tab), desktop or Big Picture: a
    /// transparent panel over the game, shown only while the client's
    /// `RegisterForOverlayActivated` says it is active.
    case gameOverlay
    /// Steam's generic modal dialog (`PopupWindow_…`), such as "Shutting down
    /// Steam": a non-activating panel centered on the desktop window as its
    /// child.
    case dialog
    /// Anything else Steam pops out: game notes, broadcasts, the overlay.
    case auxiliary

    init(popupName: String) {
        let base = Self.base(ofPopupNamed: popupName)
        self = Self.names.first { $0.match.matches(base: base) }?.role ?? .auxiliary
    }

    /// How Steam spells one popup's name.
    enum NameMatch: Equatable, Sendable {
        /// The whole base. Exact, or `SP DesktopLoginWindow` would classify
        /// as the desktop window.
        case exact(String)
        /// The start of a base Steam numbers or suffixes per instance
        /// (`contextmenu_10`, `notificationtoasts_1_desktop`).
        case prefix(String)

        func matches(base: String) -> Bool {
            switch self {
            case let .exact(name): base == name
            case let .prefix(start): base.hasPrefix(start)
            }
        }
    }

    /// Every name Steam gives a popup and its role, read by
    /// ``init(popupName:)`` and by the twin sweep. Fixed bases come first, so
    /// a prefix cannot take a name a fixed base claims.
    static let names: [(match: NameMatch, role: SteamWindowRole)] = [
        (.exact("SP Desktop"), .desktop),
        (.exact("SP BPM"), .bigPicture),
        (.exact("SP DesktopLoginWindow"), .login),
        (.exact("SP Keyboard"), .keyboard),
        (.exact("SP Controller Configurator"), .controllerConfig),
        (.prefix("contextmenu_"), .menu),
        (.prefix("friendslist"), .friends),
        (.prefix("chat_"), .chat),
        (.prefix("notificationtoasts"), .toast),
        (.prefix("desktopoverlay"), .gameOverlay),
        (.prefix("gamepadoverlay"), .gameOverlay),
        (.prefix("PopupWindow_"), .dialog),
    ]

    /// A popup's name before its `_uid<pid>` suffix.
    static func base(ofPopupNamed popupName: String) -> String {
        guard let range = popupName.range(of: "_uid") else { return popupName }
        return String(popupName[..<range.lowerBound])
    }

    /// The kinds this app draws itself, so the bottled client's copy is safe
    /// to hide. Every other kind (install or EULA modal, sign-in, a menu, a
    /// game's popup) exists only in the client and must stay.
    static let twinRoles: Set<SteamWindowRole> = [.toast, .desktop, .friends, .chat]

    /// The names of ``twinRoles``.
    static var twinNames: [NameMatch] {
        names.filter { twinRoles.contains($0.role) }.map(\.match)
    }

    /// Which UI instance opened a popup, from its `_uid<n>` suffix: 0 is the
    /// desktop UI, and a game's overlay stamps the game's pid
    /// (`friendslist_uid2220`).
    static func instanceUID(ofPopupNamed popupName: String) -> Int {
        guard let range = popupName.range(of: "_uid", options: .backwards) else { return 0 }
        return Int(popupName[range.upperBound...]) ?? 0
    }

    /// Panels never activate the app. The game overlay takes key while
    /// active but must never promote the app to a regular one.
    var isPanel: Bool {
        self == .menu || self == .keyboard || self == .gameOverlay || self == .dialog
    }

    /// Whether the window is one of Steam's ordinary popups (friends, chat,
    /// the configurator, notes) whose page draws its strip inside a header of
    /// its own (`.titleBarContainer`); these get
    /// ``SteamDesktopChrome/popupChromeScript``.
    var hasPopupChrome: Bool {
        switch self {
        case .auxiliary, .controllerConfig, .chat, .friends: true
        default: false
        }
    }

    /// Whether this window may ever be put on screen; a toast's page runs
    /// parked and is answered by a macOS notification.
    var isShowable: Bool {
        self != .toast
    }

    /// Whether a frame that lands on no display is a mistake. Menus park
    /// off-screen between uses, toasts are never shown, the keyboard places
    /// itself, and the overlay follows the game.
    var needsAReachableFrame: Bool {
        switch self {
        case .context, .menu, .keyboard, .toast, .gameOverlay: false
        case .desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog: true
        }
    }

    /// Whether WebKit may mark this window's page hidden when covered, which
    /// stops animations, rAF and layer commits. Off for the context page
    /// (zero-size window), toasts (never shown, timer still ticks), and
    /// pop-up-level panels, which report occluded even while visible and
    /// then flicker in Steam's menu re-measure loop.
    var allowsOcclusionDetection: Bool {
        switch self {
        case .context, .menu, .keyboard, .toast, .gameOverlay: false
        case .desktop, .bigPicture, .login, .controllerConfig, .auxiliary, .friends, .chat, .dialog: true
        }
    }
}
