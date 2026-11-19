import Foundation

/// The Dock tile's menu as data, which ``AppDelegate`` turns into an `NSMenu`
/// each time the Dock asks.
///
/// The groups follow Steam's own tray menu: recent games; Store, Library,
/// Community; Friends, Settings; Big Picture. The persona states sit in a
/// submenu at the end, one row instead of five.
enum DockMenu {
    /// A place in Steam's window the menu opens.
    enum Destination: CaseIterable {
        case store
        case library
        case community
        case friends
        case settings
        case bigPicture

        /// Steam's own tray wording (`#TaskbarOption_*`).
        var title: String {
            switch self {
            case .store: String(localized: "Store")
            case .library: String(localized: "Library")
            case .community: String(localized: "Community")
            case .friends: String(localized: "Friends")
            case .settings: String(localized: "Settings")
            case .bigPicture: String(localized: "Big Picture")
            }
        }

        /// The URL Steam's tray item runs. The friends list has none and opens
        /// through ``SteamWebHost/openFriends()``.
        var steamURL: URL? {
            switch self {
            case .store: URL(string: "steam://store")
            case .library: URL(string: "steam://open/library")
            case .community: URL(string: "steam://url/CommunityHome")
            case .friends: nil
            case .settings: URL(string: "steam://open/settings")
            case .bigPicture: URL(string: "steam://open/bigpicture")
            }
        }
    }

    enum Entry: Equatable {
        case game(SteamWebHost.RecentGame)
        case destination(Destination, isEnabled: Bool)
        /// The "Set Friends Status" submenu.
        case friendsStatus([SteamMenuMirror.StatusChoice], isEnabled: Bool)
        case separator
    }

    static let destinationGroups: [[Destination]] = [
        [.store, .library, .community],
        [.friends, .settings],
        [.bigPicture],
    ]

    /// The menu's rows. Recent games stay live, since the supervisor waits for
    /// a client; the page rows go dim until the client is healthy, so the menu
    /// keeps one shape. The status submenu appears once the Friends menu has
    /// been read, since its labels are Steam's.
    static func entries(
        recentGames: [SteamWebHost.RecentGame],
        statuses: [SteamMenuMirror.StatusChoice],
        clientIsReady: Bool,
    ) -> [Entry] {
        var groups: [[Entry]] = []
        if !recentGames.isEmpty {
            groups.append(recentGames.map(Entry.game))
        }
        for group in destinationGroups {
            groups.append(group.map { .destination($0, isEnabled: clientIsReady) })
        }
        if !statuses.isEmpty {
            groups.append([.friendsStatus(statuses, isEnabled: clientIsReady)])
        }
        return Array(groups.joined(separator: [.separator]))
    }
}
