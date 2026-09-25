import AppKit

/// Asks what to do with a game whose window has stopped answering: its main thread is
/// silent, so its own close button and Quit reach nothing, and this app is the one place
/// left to end it from.
@MainActor
enum NotAnsweringPrompt {
    /// True when the user chose to end the game.
    static func userEnds(_ name: String) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "\u{201C}\(name)\u{201D} has stopped answering")
        alert.informativeText = String(localized: "Its window no longer takes clicks, keys or its close button. Ending it loses anything it has not saved.")
        alert.addButton(withTitle: String(localized: "Keep Waiting"))
        alert.addButton(withTitle: String(localized: "End Game")).hasDestructiveAction = true
        // An agent app has no activation of its own, and the alert would open behind the game.
        alert.window.level = .floating
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
