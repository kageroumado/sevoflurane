import Foundation
import Testing
@testable import Sevoflurane

/// How the popover's index files the library, decided without a client.
struct LibraryIndexTests {
    private func game(_ id: Int, _ name: String, sortAs: String? = nil) -> SteamWebHost.RecentGame {
        .init(id: id, name: name, sortAs: sortAs)
    }

    @Test
    func `games sort by the name Steam's library sorts by`() {
        let witcher = game(292_030, "The Witcher 3: Wild Hunt", sortAs: "Witcher 3: Wild Hunt")
        let terraria = game(105_600, "Terraria")
        let sorted = LibraryIndex.sorted([witcher, terraria])
        #expect(sorted.map(\.id) == [terraria.id, witcher.id])
        #expect(LibraryIndex.heading(for: witcher.sortName) == "W")
    }

    @Test
    func `an empty sort name falls back to the display name`() {
        #expect(game(1, "Hades", sortAs: "").sortName == "Hades")
    }

    @Test
    func `numbers in names sort by value`() {
        let sorted = LibraryIndex.sorted([game(2, "Game 10"), game(1, "Game 2")])
        #expect(sorted.map(\.name) == ["Game 2", "Game 10"])
    }

    @Test
    func `equal names keep one order by app id`() {
        let sorted = LibraryIndex.sorted([game(9, "Portal"), game(3, "Portal")])
        #expect(sorted.map(\.id) == [3, 9])
    }

    @Test
    func `a letter is read with its accent and case folded`() {
        #expect(LibraryIndex.heading(for: "Ōkami HD") == "O")
        #expect(LibraryIndex.heading(for: "éternel") == "E")
        #expect(LibraryIndex.heading(for: "  balatro") == "B")
    }

    @Test
    func `digits, symbols and other scripts go under the other heading`() {
        #expect(LibraryIndex.heading(for: "7 Days to Die") == LibraryIndex.otherHeading)
        #expect(LibraryIndex.heading(for: "!Anyway") == LibraryIndex.otherHeading)
        #expect(LibraryIndex.heading(for: "東方") == LibraryIndex.otherHeading)
        #expect(LibraryIndex.heading(for: "") == LibraryIndex.otherHeading)
    }

    @Test
    func `the other heading comes first and letters follow in order`() {
        let sections = LibraryIndex.sections([
            game(1, "Valheim"), game(2, "Automobilista 2"), game(3, "7 Days to Die"),
            game(4, "Assetto Corsa"), game(5, "ELDEN RING"),
        ])
        #expect(sections.map(\.heading) == ["#", "A", "E", "V"])
        #expect(sections[1].games.map(\.name) == ["Assetto Corsa", "Automobilista 2"])
    }

    @Test
    func `a letter with no games has no heading`() {
        #expect(LibraryIndex.sections([]).isEmpty)
        #expect(LibraryIndex.sections([game(1, "Factorio")]).map(\.heading) == ["F"])
    }
}
