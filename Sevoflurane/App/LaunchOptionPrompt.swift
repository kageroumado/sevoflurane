import AppKit

/// Asks which way to start a game Steam lists more than one way to start: the
/// question Steam's own launch-option dialog asks, put as a native alert.
@MainActor
enum LaunchOptionPrompt {
    /// How many options fit as buttons; past that the alert carries a menu.
    static let buttonLimit = 3

    /// The chosen option's index, or nil when the user canceled.
    static func choose(from options: [LaunchOption], for name: String) -> Int? {
        let alert = NSAlert()
        alert.messageText = "\u{201C}\(name)\u{201D} can start more than one way"
        alert.informativeText = "Choose how to start it."
        // An agent app has no activation of its own, and the alert would open behind the game.
        alert.window.level = .floating
        NSApp.activate()
        if options.count <= buttonLimit {
            for option in options { alert.addButton(withTitle: option.description) }
            alert.addButton(withTitle: "Cancel")
            let response = alert.runModal()
            let position = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard options.indices.contains(position) else { return nil }
            return options[position].index
        }
        let menu = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 300, height: 26), pullsDown: false)
        for option in options { menu.addItem(withTitle: option.description) }
        alert.accessoryView = menu
        alert.addButton(withTitle: "Play")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn,
              options.indices.contains(menu.indexOfSelectedItem) else { return nil }
        return options[menu.indexOfSelectedItem].index
    }
}
