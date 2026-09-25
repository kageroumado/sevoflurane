import Foundation

/// How the popover's index files the library: by the name Steam's own library
/// sorts by, under a heading for its first letter.
///
/// A letter is folded before it is read, so "Ōkami" and "Éternel" sit under O
/// and E beside everything else there. A title that starts with a digit, a
/// symbol or a letter outside A to Z is filed under "#", which comes first, as
/// digits do in Steam's library.
nonisolated enum LibraryIndex {
    /// One heading of the index and the games under it.
    struct Section: Identifiable, Equatable, Sendable {
        let heading: String
        let games: [SteamWebHost.RecentGame]

        var id: String { heading }
    }

    /// The heading for names that start with no letter from A to Z.
    static let otherHeading = "#"

    /// The games in index order: by sort name as Finder orders names, which
    /// puts "Game 2" before "Game 10", then by app id so equal names keep one
    /// order from refresh to refresh.
    static func sorted(_ games: [SteamWebHost.RecentGame]) -> [SteamWebHost.RecentGame] {
        games.sorted { lhs, rhs in
            switch lhs.sortName.localizedStandardCompare(rhs.sortName) {
            case .orderedAscending: true
            case .orderedDescending: false
            case .orderedSame: lhs.id < rhs.id
            }
        }
    }

    /// The index's headings in order, each with its games; a letter with no
    /// games has no heading.
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
