import Foundation

/// The client popups a sweep leaves on screen: the windows a launch in flight
/// is waiting on, which the client alone can show.
///
/// Steam's launch-option dialog is a popup named after the game
/// (`Black Myth: Wukong Benchmark Tool_uid0`), and a sweep that hides it
/// leaves the launch waiting on an answer nobody can give. The name is known
/// while the launch is; anything else the desktop UI puts up under a name the
/// role table does not know is spared on the same grounds, since the table
/// names every window this app draws for itself.
nonisolated struct PopupSparing: Sendable, Equatable {
    /// Popup bases spared by name: the game a launch is in flight for.
    var exactBases: [String] = []
    /// Whether a desktop-UI popup (`_uid0`) whose base matches nothing in
    /// ``SteamWindowRole/names`` is spared. A game overlay's popups carry the
    /// game's pid and are never in this set.
    var unclassifiedDesktopPopups = false

    /// Spares nothing: the sweep as the stop path and the supervisor run it.
    static let none = PopupSparing()

    func spares(popupNamed name: String) -> Bool {
        let base = SteamWindowRole.base(ofPopupNamed: name)
        if exactBases.contains(base) || exactBases.contains(name) { return true }
        guard unclassifiedDesktopPopups, SteamWindowRole.instanceUID(ofPopupNamed: name) == 0
        else { return false }
        return !SteamWindowRole.names.contains { $0.match.matches(base: base) }
    }
}
