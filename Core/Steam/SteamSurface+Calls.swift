import Foundation

/// The `SteamClient` methods the app calls, routes to the Mac, or listens in on.
nonisolated extension SteamSurface {
    /// One `SteamClient` method, by its path.
    ///
    /// The client refuses a call that passes fewer arguments than its own
    /// code does, and says so only on its console. ``Facts/passes`` records
    /// what the app passes, and the audit compares it with the calls in
    /// Steam's own scripts.
    enum Call: String, CaseIterable, Sendable {
        // Apps
        case addShortcut = "SteamClient.Apps.AddShortcut"
        case browseScreenshotForApp = "SteamClient.Apps.BrowseScreenshotForApp"
        case cancelGameAction = "SteamClient.Apps.CancelGameAction"
        case continueGameAction = "SteamClient.Apps.ContinueGameAction"
        case createDesktopShortcutForApp = "SteamClient.Apps.CreateDesktopShortcutForApp"
        case getGameActionDetails = "SteamClient.Apps.GetGameActionDetails"
        case getGameActionForApp = "SteamClient.Apps.GetGameActionForApp"
        case getLaunchOptionsForApp = "SteamClient.Apps.GetLaunchOptionsForApp"
        case registerForAppDetails = "SteamClient.Apps.RegisterForAppDetails"
        case registerForGameActionEnd = "SteamClient.Apps.RegisterForGameActionEnd"
        case registerForGameActionShowError = "SteamClient.Apps.RegisterForGameActionShowError"
        case registerForGameActionStart = "SteamClient.Apps.RegisterForGameActionStart"
        case registerForGameActionTaskChange = "SteamClient.Apps.RegisterForGameActionTaskChange"
        case registerForGameActionUserRequest = "SteamClient.Apps.RegisterForGameActionUserRequest"
        case removeShortcut = "SteamClient.Apps.RemoveShortcut"
        case runGame = "SteamClient.Apps.RunGame"
        case setAppLaunchOptions = "SteamClient.Apps.SetAppLaunchOptions"
        case setShortcutExe = "SteamClient.Apps.SetShortcutExe"
        case setShortcutLaunchOptions = "SteamClient.Apps.SetShortcutLaunchOptions"
        case setShortcutName = "SteamClient.Apps.SetShortcutName"
        case setShortcutStartDir = "SteamClient.Apps.SetShortcutStartDir"
        case specifyCompatTool = "SteamClient.Apps.SpecifyCompatTool"
        case subscribeWorkshopItem = "SteamClient.Apps.SubscribeWorkshopItem"
        case terminateApp = "SteamClient.Apps.TerminateApp"
        case verifyApp = "SteamClient.Apps.VerifyApp"
        // Browser
        case getBrowserID = "SteamClient.Browser.GetBrowserID"
        // Console
        case execCommand = "SteamClient.Console.ExecCommand"
        case registerForSpewOutput = "SteamClient.Console.RegisterForSpewOutput"
        // Downloads
        case enableAllDownloads = "SteamClient.Downloads.EnableAllDownloads"
        case registerForDownloadOverview = "SteamClient.Downloads.RegisterForDownloadOverview"
        // GameSessions
        case registerForAppLifetimeNotifications = "SteamClient.GameSessions.RegisterForAppLifetimeNotifications"
        // InstallFolder
        case browseFilesInFolder = "SteamClient.InstallFolder.BrowseFilesInFolder"
        case getInstallFolders = "SteamClient.InstallFolder.GetInstallFolders"
        // Installs
        case continueInstall = "SteamClient.Installs.ContinueInstall"
        case getInstallManagerInfo = "SteamClient.Installs.GetInstallManagerInfo"
        case openInstallWizard = "SteamClient.Installs.OpenInstallWizard"
        case openUninstallWizard = "SteamClient.Installs.OpenUninstallWizard"
        case registerForShowInstallWizard = "SteamClient.Installs.RegisterForShowInstallWizard"
        case setCreateShortcuts = "SteamClient.Installs.SetCreateShortcuts"
        // Overlay
        case registerForOverlayActivated = "SteamClient.Overlay.RegisterForOverlayActivated"
        case setOverlayState = "SteamClient.Overlay.SetOverlayState"
        // Screenshots
        case showScreenshotsOnDisk = "SteamClient.Screenshots.ShowScreenshotsOnDisk"
        // Settings
        case openWindowsMicSettings = "SteamClient.Settings.OpenWindowsMicSettings"
        case setSetting = "SteamClient.Settings.SetSetting"
        // Storage
        case deleteKey = "SteamClient.Storage.DeleteKey"
        case getString = "SteamClient.Storage.GetString"
        // System
        case getProxyInfo = "SteamClient.System.Network.GetProxyInfo"
        case openFileDialog = "SteamClient.System.OpenFileDialog"
        case openInSystemBrowser = "SteamClient.System.OpenInSystemBrowser"
        case openLocalDirectoryInSystemExplorer = "SteamClient.System.OpenLocalDirectoryInSystemExplorer"
        // URL
        case executeSteamURL = "SteamClient.URL.ExecuteSteamURL"
        case registerForRunSteamURL = "SteamClient.URL.RegisterForRunSteamURL"
        // User
        case reconnect = "SteamClient.User.Reconnect"
        case startShutdown = "SteamClient.User.StartShutdown"
        // WebChat
        case setNumChatsWithUnreadPriorityMessages = "SteamClient.WebChat.SetNumChatsWithUnreadPriorityMessages"

        /// The method's dotted path, `SteamClient.Apps.RunGame`.
        var path: String { rawValue }

        /// The JavaScript of one call, each argument given as JavaScript.
        func invocation(_ arguments: String...) -> String {
            "\(rawValue)(\(arguments.joined(separator: ", ")))"
        }
    }

    /// What the catalog records about one call.
    struct Facts: Sendable, Equatable {
        /// The arguments the app's calls pass; nil for a call the app only
        /// routes or listens in on.
        var passes: Int?
        /// Whether Steam's own scripts called the method when this was written.
        var steamCalls = true
        /// The parameter counts of Steam's own handlers, for a registration
        /// whose callback arguments the app reads by position.
        var handler: [Int]?
        let use: String
    }

    static let calls: [Entry] = Call.allCases.map { call in
        let facts = call.facts
        return Entry(
            .call, call.path, facts.use,
            .call(passes: facts.passes, steamCalls: facts.steamCalls, handler: facts.handler),
        )
    }
}

nonisolated extension SteamSurface.Call {
    var facts: SteamSurface.Facts {
        typealias Facts = SteamSurface.Facts
        return switch self {
        case .addShortcut:
            Facts(passes: 4, use: "adding a Windows program to the library")
        case .browseScreenshotForApp:
            Facts(use: "routed to Finder: a game's screenshot folder")
        case .cancelGameAction:
            Facts(passes: 1, use: "canceling a launch from the Mac's launch-option chooser")
        case .continueGameAction:
            Facts(passes: 2, use: "answering a launch-option request with the chosen option")
        case .createDesktopShortcutForApp:
            Facts(use: "answered on the Mac: an alias of the game's bundle on the desktop")
        case .getGameActionDetails:
            Facts(passes: 2, use: "sevo: the task a launch is waiting on")
        case .getGameActionForApp:
            Facts(passes: 2, use: "sevo: the launch in progress for a game")
        case .getLaunchOptionsForApp:
            Facts(passes: 1, use: "the launch options the Mac's chooser lists")
        case .registerForAppDetails:
            Facts(passes: 2, handler: [1], use: "reading a game's stored launch options; the main-thread probe")
        case .registerForGameActionEnd:
            Facts(passes: 1, handler: [0, 1], use: "the launch watch: a launch ended")
        case .registerForGameActionShowError:
            Facts(passes: 1, handler: [4, 5], use: "the launch watch: Steam's launch error (action id, app id, action, error, detail)")
        case .registerForGameActionStart:
            Facts(passes: 1, handler: [3, 4], use: "the launch watch: a launch began (action id, app id, action)")
        case .registerForGameActionTaskChange:
            Facts(passes: 1, handler: [4, 5], use: "the launch watch: the launch's current task (action id, app id, task)")
        case .registerForGameActionUserRequest:
            Facts(passes: 1, handler: [4, 5], use: "the launch-option request (action id, app id, action, request)")
        case .removeShortcut:
            Facts(passes: 1, use: "removing a Windows program from the library")
        case .runGame:
            Facts(passes: 4, use: "launching a game; every launch passes the bridge here")
        case .setAppLaunchOptions:
            Facts(passes: 2, use: "storing a game's launch options with the app's wrapper command")
        case .setShortcutExe:
            Facts(passes: 2, use: "pointing a library shortcut at its program")
        case .setShortcutLaunchOptions:
            Facts(passes: 2, use: "a library shortcut's launch options")
        case .setShortcutName:
            Facts(passes: 2, use: "naming a library shortcut")
        case .setShortcutStartDir:
            Facts(passes: 2, use: "a library shortcut's working folder")
        case .specifyCompatTool:
            Facts(passes: 2, steamCalls: false, use: "mapping a game to its macOS or Windows build")
        case .subscribeWorkshopItem:
            Facts(passes: 3, use: "subscribing to a companion's Workshop item its partner app asks for")
        case .terminateApp:
            Facts(passes: 2, use: "stopping a game")
        case .verifyApp:
            Facts(passes: 1, use: "sevo app verify")
        case .getBrowserID:
            Facts(use: "answered by the shim: each window's browser id")
        case .execCommand:
            Facts(passes: 1, use: "sevo downloads throttle")
        case .registerForSpewOutput:
            Facts(passes: 1, handler: [1], use: "logging each call the client refuses")
        case .enableAllDownloads:
            Facts(passes: 2, use: "sevo downloads pause and resume")
        case .registerForDownloadOverview:
            Facts(passes: 1, handler: [1], use: "sevo downloads status")
        case .registerForAppLifetimeNotifications:
            Facts(passes: 1, handler: [1], use: "the launch watch: a game's process started or ended")
        case .browseFilesInFolder:
            Facts(use: "routed to Finder: a library folder")
        case .getInstallFolders:
            Facts(passes: 0, use: "resolving a library folder's path for Finder")
        case .continueInstall:
            Facts(passes: 0, use: "sevo app install: the wizard's next page")
        case .getInstallManagerInfo:
            Facts(passes: 0, steamCalls: false, use: "sevo app install; the main-thread probe")
        case .openInstallWizard:
            Facts(passes: 2, use: "opening Steam's install wizard for one game on this computer")
        case .openUninstallWizard:
            Facts(passes: 3, use: "sevo app uninstall")
        case .registerForShowInstallWizard:
            Facts(passes: 1, handler: [1], use: "knowing the install wizard opened")
        case .setCreateShortcuts:
            Facts(passes: 2, use: "sevo app install: no Windows shortcuts")
        case .registerForOverlayActivated:
            Facts(passes: 1, handler: [4], use: "showing the overlay with its game (pid, app id, active)")
        case .setOverlayState:
            Facts(passes: 2, use: "closing the overlay on Shift+Tab")
        case .showScreenshotsOnDisk:
            Facts(use: "routed to Finder: a game's screenshot folder")
        case .openWindowsMicSettings:
            Facts(use: "routed to the Mac's Sound settings")
        case .setSetting:
            Facts(passes: 2, use: "restoring Steam's rendering settings after Low Power Mode")
        case .deleteKey:
            Facts(passes: 1, use: "forgetting a remembered launch option")
        case .getString:
            Facts(passes: 1, use: "reading the remembered launch option")
        case .getProxyInfo:
            Facts(passes: 0, use: "the main-thread probe")
        case .openFileDialog:
            Facts(use: "answered on the Mac: the open and save panels")
        case .openInSystemBrowser:
            Facts(use: "routed to the Mac's browser")
        case .openLocalDirectoryInSystemExplorer:
            Facts(use: "routed to Finder: Browse local files")
        case .executeSteamURL:
            Facts(passes: 1, use: "running a steam:// link the page has no handler for")
        case .registerForRunSteamURL:
            Facts(handler: [2], use: "dispatching steam:// links to the page's own handlers (count, URL)")
        case .reconnect:
            Facts(passes: 0, use: "reconnecting after the Mac wakes or the network returns")
        case .startShutdown:
            Facts(passes: 1, use: "asking the client to quit")
        case .setNumChatsWithUnreadPriorityMessages:
            Facts(use: "listened in on: the unread-chat count for the menu bar")
        }
    }
}
