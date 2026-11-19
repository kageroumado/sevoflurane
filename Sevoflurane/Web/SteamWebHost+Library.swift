import Foundation

/// How the popover's index files the library: by Steam's sort name, under its
/// folded first letter ("Ōkami" under O), or under "#" first for anything
/// outside A to Z.
nonisolated enum LibraryIndex {
    /// One heading of the index and the games under it.
    struct Section: Identifiable, Equatable, Sendable {
        let heading: String
        let games: [SteamWebHost.RecentGame]

        var id: String { heading }
    }

    /// The heading for names that start with no letter from A to Z.
    static let otherHeading = "#"

    /// The games by sort name in Finder order ("Game 2" before "Game 10"),
    /// then by app id so the order is stable.
    static func sorted(_ games: [SteamWebHost.RecentGame]) -> [SteamWebHost.RecentGame] {
        games.sorted { lhs, rhs in
            switch lhs.sortName.localizedStandardCompare(rhs.sortName) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }

    /// The non-empty headings in order, each with its games.
    static func sections(_ games: [SteamWebHost.RecentGame]) -> [Section] {
        let byHeading = Dictionary(grouping: sorted(games)) { heading(for: $0.sortName) }
        return byHeading.keys
            .sorted { lhs, rhs in
                if lhs == otherHeading { return rhs != otherHeading }
                if rhs == otherHeading { return false }
                return lhs < rhs
            }
            .map { Section(heading: $0, games: byHeading[$0] ?? []) }
    }

    /// The heading a name is filed under.
    static func heading(for name: String) -> String {
        let folded = name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
        guard let first = folded.unicodeScalars.first, ("a" ... "z").contains(first) else {
            return otherHeading
        }
        return String(first).uppercased()
    }
}

extension SteamWebHost {
    nonisolated struct RecentGame: Identifiable, Decodable, Equatable, Sendable {
        let id: Int
        let name: String
        /// What Steam's library shows under the name, by the client's own numbering.
        var displayStatus: Int?
        /// Steam's sort name (`sort_as`): no leading article, romanized.
        var sortAs: String?

        var sortName: String {
            guard let sortAs, !sortAs.isEmpty else { return name }
            return sortAs
        }

        /// Synchronizing (8): Steam Cloud has the game's saves in hand.
        var isInCloudSync: Bool { displayStatus == 8 }

        /// Capsule art, served by the bridge (local cache, CDN fallback).
        var artURL: URL {
            URL(string: "http://127.0.0.1:\(BridgePorts.art)/art/\(id).jpg")!
        }
    }
}
