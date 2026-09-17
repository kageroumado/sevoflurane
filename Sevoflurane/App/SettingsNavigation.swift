import Observation

/// The selected settings pane and row, owned by the settings window.
@MainActor
@Observable
final class SettingsNavigation {
    var category: SettingsCategory = .general
    var searchText = ""
    var highlighted: SettingsAnchor?

    func showRecovery() {
        category = .recovery
        searchText = ""
        highlighted = nil
    }
}
