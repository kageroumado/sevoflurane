import AppKit

/// The question Steam's Linux client asks at Install for a game known not to
/// run there, asked here for a game known not to run on a Mac: anti-cheat
/// that cannot load, or an Unsupported verdict.
///
/// A native alert rather than a dialog drawn into Steam's page: the
/// decision is made where the install passes through the bridge, from a
/// verdict that lives on this side, so it needs no anchor in Steam's
/// markup, and it reads like the app's other questions (``LaunchOptionPrompt``).
@MainActor
enum InstallWarning {
    /// How long Install waits for the verdict before going ahead without
    /// one. The game's page has usually asked already, so the answer is on
    /// disk.
    static let patience: Duration = .seconds(5)

    /// The alert's headline and body for one risk.
    static func text(for risk: GameCompatInstallRisk, name: String, nativePlays: Bool) -> (title: String, message: String) {
        let native = nativePlays
            ? " " + String(localized: "Its macOS version plays, and Steam for Mac runs that one directly.") : ""
        switch risk {
        case let .antiCheat(reason, gameStarts):
            let starts = gameStarts ? " " + String(localized: "The game may start; the modes the anti-cheat guards stay closed.") : ""
            return (
                String(localized: "\u{201C}\(name)\u{201D} uses anti-cheat that blocks it on a Mac"),
                reason + starts + native,
            )
        case let .unsupported(reason):
            return (String(localized: "\u{201C}\(name)\u{201D} may fail on a Mac"), reason + native)
        }
    }

    /// Asks, and answers whether to install.
    static func ask(_ risk: GameCompatInstallRisk, name: String, nativePlays: Bool) -> Bool {
        let (title, message) = text(for: risk, name: name, nativePlays: nativePlays)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Install Anyway"))
        // An agent app has no activation of its own, and the alert would open behind Steam.
        alert.window.level = .floating
        NSApp.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}
