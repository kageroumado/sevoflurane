import AppKit

/// What a Play of a companion app (``GameCompanion``) becomes: the partner
/// app, since the companion's own window never draws here. Every Play path
/// asks here after ``MacBuildHandoff``: the bridge's `RunGame`, the menu bar
/// and the Dock.
@MainActor
enum CompanionHandoff {
    static func isInstalled(_ companion: GameCompanion) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: companion.partnerBundleID) != nil
    }

    /// Opens the partner where the downloads show, or its page when it is
    /// not installed: the strip's pill.
    static func open(appID: Int) {
        guard let companion = GameCompanion.all[appID] else { return }
        let installed = isInstalled(companion)
        EventLog.shared.log(.client, "\(companion.name): opening \(installed ? companion.partner : "its page")")
        NSWorkspace.shared.open(installed ? companion.openURL : companion.pageURL)
    }

    /// Opens the companion's Workshop page in Steam, through the app's own
    /// `steam://` handler, which brings the client forward.
    static func openWorkshop(appID: Int) {
        guard let companion = GameCompanion.all[appID] else { return }
        EventLog.shared.log(.client, "\(companion.name): opening its Workshop")
        NSWorkspace.shared.open(companion.workshopURL)
    }

    /// Takes a Play of a companion app, whose own window never draws here:
    /// says what the app is for, opens its Workshop by default, and offers
    /// the partner. `false` for an app that is no companion.
    static func take(appID: Int) -> Bool {
        guard let companion = GameCompanion.all[appID] else { return false }
        let installed = isInstalled(companion)
        let alert = NSAlert()
        alert.messageText = String(localized: "\(companion.name) wallpapers play through \(companion.partner)")
        alert.informativeText = installed
            ? companion.reason
            : companion.reason + " " + String(localized: "\(companion.partner) is free, from the maker of Sevoflurane.")
        alert.addButton(withTitle: String(localized: "Open Workshop"))
        alert.addButton(withTitle: installed
            ? String(localized: "Open \(companion.partner)") : String(localized: "Get \(companion.partner)"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        // An agent app has no activation of its own, and the alert would open behind Steam.
        alert.window.level = .floating
        NSApp.activate()
        switch alert.runModal() {
        case .alertFirstButtonReturn: openWorkshop(appID: appID)
        case .alertSecondButtonReturn: open(appID: appID)
        default: break
        }
        return true
    }

    /// ``take(appID:)`` for a Play that arrives inside an await: the alert
    /// runs on the main run loop's next turn, as ``InstallWarning`` does.
    static func takeRunGame(appID: Int) async -> Bool {
        guard GameCompanion.all[appID] != nil else { return false }
        return await withCheckedContinuation { continuation in
            ModalAlerts.present {
                continuation.resume(returning: take(appID: appID))
            }
        }
    }
}
