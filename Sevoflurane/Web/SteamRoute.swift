import Foundation

/// A destination in Steam's own router.
///
/// The cases are the subset of `MainWindowInstance.Navigator` that the desktop
/// UI renders natively. Store and Community are deliberately absent: they are
/// `BrowserView` content, which the shim still stands in for. Navigation from
/// the menu bar goes through ``SteamMenuMirror`` instead; these routes serve
/// programmatic navigation, like the boot into the library.
enum SteamRoute: String {
    case library
    case downloads
    case friends
    case settings

    var navigatorFunction: String {
        switch self {
        case .library: "Home"
        case .downloads: "Downloads"
        case .friends: "Chat"
        case .settings: "Settings"
        }
    }
}
