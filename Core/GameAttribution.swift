import Foundation

nonisolated extension GameConfig {
    /// Whether `appID`'s records claim executables: an adopted program's
    /// always, a Steam game's while a library holds its manifest
    /// (`installed`). A game that is not installed starts no process, so no
    /// window and no env file is its, however many exes it has on record.
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

    /// The app whose recorded exes include this one, if any: a window owned
    /// by an exe another game has already claimed is that game's, whatever
    /// launch is in flight.
    static func app(claiming exe: String) -> Int? {
        app(claiming: exe, in: claimingGames())
    }

    /// ``app(claiming:)`` over `games`. Two games that both record the exe
    /// answer the lower app id, so the answer is the same whatever order the
    /// store lists them in.
    static func app(claiming exe: String, in games: [Int: ConfigValues]) -> Int? {
        let lowered = exe.lowercased()
        guard GameExecutables.isRecordable(lowered) else { return nil }
        return games.filter { $0.value.exes?.contains(lowered) == true }.keys.min()
    }
}
