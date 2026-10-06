import Foundation
import Testing
@testable import Sevoflurane

@MainActor
struct DockMenuTests {
    private typealias Item = SteamMenuMirror.MirroredItem
    private typealias Game = SteamWebHost.RecentGame

    private func command(_ label: String, on: Bool = false, disabled: Bool = false) -> Item {
        Item(sep: nil, label: label, on: on, disabled: disabled)
    }

    /// The Friends root menu as the live client reports it.
    private var friendsMenu: [Item] {
        [
            command("View Friends List (2 Online)"), Item(sep: true),
            command("Add a Friend..."), command("Edit Profile Name/Avatar..."), Item(sep: true),
            command("Online"), command("Away", on: true), command("Invisible"), command("Offline"),
        ]
    }

    private let games = [Game(id: 10, name: "Counter-Strike"), Game(id: 20, name: "Portal")]

    // MARK: - Friends status

    @Test
    func `the Friends menu's last group becomes the four statuses, with their click indices`() {
        let statuses = SteamMenuMirror.statusChoices(in: friendsMenu)
        #expect(statuses.map(\.label) == ["Online", "Away", "Invisible", "Offline"])
        #expect(statuses.map(\.childIndex) == [5, 6, 7, 8])
        #expect(statuses.map(\.isCurrent) == [false, true, false, false])
        #expect(statuses.map(\.isEnabled) == [true, true, true, true])
    }

    @Test
    func `statuses are found by position, so Steam's language does not matter`() {
        var menu = friendsMenu
        for (offset, label) in ["在线", "离开", "隐身", "离线"].enumerated() {
            menu[5 + offset] = command(label, on: offset == 0)
        }
        let statuses = SteamMenuMirror.statusChoices(in: menu)
        #expect(statuses.map(\.label) == ["在线", "离开", "隐身", "离线"])
        #expect(statuses.first?.isCurrent == true)
    }

    @Test
    func `a menu shaped otherwise offers no statuses`() {
        #expect(SteamMenuMirror.statusChoices(in: []).isEmpty)
        #expect(SteamMenuMirror.statusChoices(in: [command("Online"), command("Away")]).isEmpty)
        #expect(SteamMenuMirror.statusChoices(in: Array(friendsMenu.dropLast())).isEmpty)
        #expect(SteamMenuMirror.statusChoices(in: friendsMenu + [Item(sep: true)]).isEmpty)
    }

    // MARK: - Menu model

    @Test
    func `games, then Steam's tray groups, then the status submenu, each set off by a rule`() {
        let statuses = SteamMenuMirror.statusChoices(in: friendsMenu)
        let entries = DockMenu.entries(recentGames: games, statuses: statuses, clientIsReady: true)
        #expect(entries == [
            .game(games[0]), .game(games[1]), .separator,
            .destination(.store, isEnabled: true), .destination(.library, isEnabled: true),
            .destination(.community, isEnabled: true), .separator,
            .destination(.friends, isEnabled: true), .destination(.settings, isEnabled: true), .separator,
            .destination(.bigPicture, isEnabled: true), .separator,
            .friendsStatus(statuses, isEnabled: true),
        ])
    }

    @Test
    func `with no recent games the menu opens on Store`() {
        let entries = DockMenu.entries(recentGames: [], statuses: [], clientIsReady: true)
        #expect(entries.first == .destination(.store, isEnabled: true))
        #expect(entries.last == .destination(.bigPicture, isEnabled: true))
        #expect(entries.count(where: { $0 == .separator }) == 2)
    }

    @Test
    func `a client that is not ready dims everything but the games`() {
        let statuses = SteamMenuMirror.statusChoices(in: friendsMenu)
        let entries = DockMenu.entries(recentGames: games, statuses: statuses, clientIsReady: false)
        for entry in entries {
            switch entry {
            case .game, .separator: break
            case let .destination(_, isEnabled), let .friendsStatus(_, isEnabled): #expect(!isEnabled)
            }
        }
        #expect(entries.count == 13)
    }

    @Test
    func `every place but Friends runs a URL a route in Steam's UI handles`() {
        let urls = DockMenu.Destination.allCases.compactMap(\.steamURL).map(\.absoluteString)
        #expect(urls == [
            "steam://store", "steam://open/library", "steam://url/CommunityHome",
            "steam://open/settings", "steam://open/bigpicture",
        ])
        #expect(DockMenu.Destination.friends.steamURL == nil)
    }
}
