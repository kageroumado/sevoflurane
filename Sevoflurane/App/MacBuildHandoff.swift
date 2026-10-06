import AppKit

/// Play for a game set to its macOS build (``GameBuild/mac``): the game goes
/// to Valve's Steam for Mac, opened by its app explicitly, and the bottle's
/// client never hears of it.
///
/// Every Play reaches here before the Windows client: the bridge's
/// `SteamClient.Apps.RunGame` for the library's Play button and `steam://`
/// links, and ``ClientSupervisor/launch(appID:name:renderer:)`` for the menu
/// bar, the Dock tile and its menu.
@MainActor
enum MacBuildHandoff {
    /// Games the app itself is starting on Windows, by when it asked, whose
    /// next Play reaches the Windows client whatever the game is set to.
    private static var windowsLaunches: [Int: ContinuousClock.Instant] = [:]
    /// As long as the helper may take to bring a client up for a launch.
    private static let windowsLaunchLife = Duration.seconds(300)

    /// Steam for Mac's app, wherever it is installed.
    static var steamForMac: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: NativeSteam.bundleIdentifier)
    }

    /// Takes one of the app's own Plays where the game is set to its macOS
    /// build. `true` when it did, and the Windows client must not start the
    /// game. A Windows launch the app asked for passes, and stays allowed for
    /// the `RunGame` it leads to.
    static func take(appID: Int, name: String? = nil) -> Bool {
        if let asked = windowsLaunches[appID], .now - asked < windowsLaunchLife { return false }
        return perform(route(appID: appID, build: GameConfig.game(appID).build), name: name)
    }

    /// Takes a `RunGame` on its way to the Windows client, as ``take(appID:name:)``
    /// does; the Windows launch it was allowed for ends here.
    static func takeRunGame(appID: Int) -> Bool {
        if let asked = windowsLaunches.removeValue(forKey: appID), .now - asked < windowsLaunchLife {
            return false
        }
        return perform(route(appID: appID, build: GameConfig.game(appID).build), name: nil)
    }

    /// Starts the macOS build whatever the game is set to: the compat strip's
    /// action.
    static func playMacBuild(appID: Int) {
        _ = perform(route(appID: appID, build: .mac), name: nil)
    }

    /// Lets the game's next Play reach the Windows client: a launch on a
    /// chosen renderer, or the Windows version picked when Steam for Mac is
    /// missing.
    static func allowWindowsLaunch(appID: Int) {
        windowsLaunches[appID] = .now
    }

    /// Looks for Steam for Mac and the game's install only for the macOS
    /// build, so a Windows Play reads one file.
    private static func route(appID: Int, build: GameBuild?) -> MacBuildRoute {
        guard build == .mac else { return .windows }
        return MacBuildRoute.decide(
            appID: appID, build: build, hasSteamForMac: steamForMac != nil,
            installedThere: NativeSteam.isInstalled(appID: appID),
        )
    }

    private static func perform(_ route: MacBuildRoute, name: String?) -> Bool {
        switch route {
        case .windows:
            return false
        case let .play(appID), let .install(appID):
            guard let link = route.link, let steam = steamForMac else { return false }
            let what = name ?? GameConfig.game(appID).name ?? String(appID)
            EventLog.shared.log(
                .client,
                route == .play(appID)
                    ? "play \(what): handed to Steam for Mac (macOS version)"
                    : "play \(what): not installed in Steam for Mac, opening its install page there",
            )
            NSWorkspace.shared.open([link], withApplicationAt: steam, configuration: NSWorkspace.OpenConfiguration()) { _, error in
                guard let error else { return }
                EventLog.shared.log(.client, "play \(what): Steam for Mac did not open \(link): \(error.localizedDescription)")
            }
            return true
        case let .steamForMacMissing(appID):
            let what = name ?? GameConfig.game(appID).name ?? String(appID)
            EventLog.shared.log(.client, "play \(what): set to the macOS version, and Steam for Mac is not installed")
            ModalAlerts.present { askWithoutSteamForMac(appID: appID, name: what) }
            return true
        }
    }

    /// The macOS version is chosen and Steam for Mac is missing: get it, or
    /// play the Windows version this once.
    private static func askWithoutSteamForMac(appID: Int, name: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Steam for Mac is not installed")
        alert.informativeText = String(localized: """
        \(name) is set to its macOS version, which plays through Valve's Steam for Mac. \
        Settings › Games sets it back to the Windows version.
        """)
        alert.addButton(withTitle: String(localized: "Get Steam for Mac"))
        alert.addButton(withTitle: String(localized: "Play the Windows Version"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if let page = URL(string: "https://store.steampowered.com/about/") { NSWorkspace.shared.open(page) }
        case .alertSecondButtonReturn:
            guard let delegate = NSApp.delegate as? AppDelegate else { return }
            allowWindowsLaunch(appID: appID)
            Task(name: "Play \(name) on Windows") { await delegate.supervisor.launch(appID: appID, name: name) }
        default:
            break
        }
    }
}
