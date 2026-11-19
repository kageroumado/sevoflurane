import Foundation

nonisolated extension GameConfig {
    /// Whether `appID`'s records claim executables: always for an adopted
    /// program, while installed for a Steam game.
    static func claims(_ appID: Int, installed: Set<Int>) -> Bool {
        AdoptedPrograms.isAdopted(appID) || installed.contains(appID)
    }

    /// The games among `games` whose records claim executables
    /// (``claims(_:installed:)``).
    static func claimants(in games: [Int: ConfigValues], installed: Set<Int>) -> [Int: ConfigValues] {
        games.filter { claims($0.key, installed: installed) }
    }

    /// The store's games whose records claim executables, by app id.
    static func claimingGames(installed: Set<Int> = SharedGames.installedAppIDs) -> [Int: ConfigValues] {
        claimants(in: games(), installed: installed)
    }

    /// The app whose recorded exes include `exe`, whatever launch is in flight.
    static func app(claiming exe: String) -> Int? {
        app(claiming: exe, in: claimingGames())
    }

    /// ``app(claiming:)`` over `games`; a shared exe answers the lower app id.
    static func app(claiming exe: String, in games: [Int: ConfigValues]) -> Int? {
        let lowered = exe.lowercased()
        guard GameExecutables.isRecordable(lowered) else { return nil }
        return games.filter { $0.value.exes?.contains(lowered) == true }.keys.min()
    }
}
