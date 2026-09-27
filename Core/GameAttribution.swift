import Foundation

nonisolated extension GameConfig {
    /// The app whose recorded exes include this one, if any: a window owned
    /// by an exe another game has already claimed is that game's, whatever
    /// launch is in flight.
    static func app(claiming exe: String) -> Int? {
        let lowered = exe.lowercased()
        return games().first { $0.value.exes?.contains(lowered) == true }?.key
    }
}
