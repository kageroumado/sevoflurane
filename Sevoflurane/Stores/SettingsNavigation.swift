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

    /// Logs the pane the window shows.
    func noteCategoryShown() {
        EventLog.shared.log(.window, "settings: showing \(category.title)")
    }

    /// Logs the sidebar search starting or clearing.
    func noteSearchChanged() {
        EventLog.shared.log(
            .window,
            searchText.isEmpty ? "settings: sidebar search cleared" : "settings: sidebar search active",
        )
    }

    /// Settings › Diagnostics on the archive row, whose (i) holds the steps
    /// for a useful report.
    func showReportGuide() {
        searchText = ""
        reveal(.diagnosticsSave)
    }

    /// Opens a row's pane and lights the row for a moment; a later reveal
    /// owns the light.
    func reveal(_ anchor: SettingsAnchor) {
        category = anchor.category
        highlighted = anchor
        Task(name: "Clear settings highlight") {
            try? await Task.sleep(for: SettingsMetrics.highlight)
            if highlighted == anchor { highlighted = nil }
        }
    }
}
