import Observation

/// The selected settings pane and row, owned by the settings window.
@MainActor
@Observable
final class SettingsNavigation {
    var category: SettingsCategory = .general
    var searchText = ""
    var highlighted: SettingsAnchor?
    /// The game Settings › Games is asked to open on. The pane takes it and
    /// clears it, so the next request for the same game still lands.
    var requestedGame: GameRequest?

    struct GameRequest: Equatable {
        let id: Int
        /// For a game that has no settings file yet, and so no name of its
        /// own in the pane's list.
        let name: String
    }

    func showGame(id: Int, name: String) {
        category = .games
        searchText = ""
        highlighted = nil
        requestedGame = GameRequest(id: id, name: name)
    }

    func showRecovery() {
        category = .recovery
        searchText = ""
        highlighted = nil
    }

    /// Settings › Diagnostics with the steps for a useful report lit.
    func showReportGuide() {
        category = .diagnostics
        searchText = ""
        highlighted = .diagnosticsGuide
    }
}
