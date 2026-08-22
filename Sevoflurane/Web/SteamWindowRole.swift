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
    /// Anything else Steam pops out: friends chat, game notes, broadcasts.
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
        default: base.hasPrefix("contextmenu_") ? .menu : .auxiliary
        }
    }

    /// Panels never activate the app or take key focus from other apps.
    var isPanel: Bool {
        self == .menu || self == .keyboard
    }
}
