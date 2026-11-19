import AppKit

/// Turns a Play of a companion app (``GameCompanion``), whose own window never
/// draws here, into its partner app. Every Play path asks here after
/// ``MacBuildHandoff``.
@MainActor
enum CompanionHandoff {
    static func isInstalled(_ companion: GameCompanion) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: companion.partnerBundleID) != nil
    }

    /// Opens the partner where the downloads show, or its page when it is not
    /// installed.
    static func open(appID: Int) {
        guard let companion = GameCompanion.all[appID] else { return }
        let installed = isInstalled(companion)
        EventLog.shared.log(.client, "\(companion.name): opening \(installed ? companion.partner : "its page")")
        NSWorkspace.shared.open(installed ? companion.openURL : companion.pageURL)
    }

    /// Opens the companion's Workshop in this app's own Steam; `steam://`
    /// through NSWorkspace would reach whichever Steam owns the scheme, Valve's
    /// included.
    static func openWorkshop(appID: Int) {
        guard let companion = GameCompanion.all[appID], let delegate = NSApp.delegate as? AppDelegate else { return }
        EventLog.shared.log(.client, "\(companion.name): opening its Workshop")
        delegate.host.showSteam()
        delegate.host.executeSteamURL(companion.workshopURL)
    }

    /// Takes a Play of a companion app: opens its Workshop and shows the guide
    /// over it. `false` for any other app.
    static func take(appID: Int) -> Bool {
        guard let companion = GameCompanion.all[appID] else { return false }
        openWorkshop(appID: appID)
        CompanionGuide.shared.show(companion)
        return true
    }

    /// ``take(appID:)`` for a Play inside an await: the panel opens on the main
    /// run loop's next turn, as ``InstallWarning`` does.
    static func takeRunGame(appID: Int) async -> Bool {
        guard GameCompanion.all[appID] != nil else { return false }
        return await withCheckedContinuation { continuation in
            ModalAlerts.present {
                continuation.resume(returning: take(appID: appID))
            }
        }
    }
}
