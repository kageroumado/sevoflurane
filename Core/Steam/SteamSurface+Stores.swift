import Foundation

/// The objects Steam's page keeps on `window`, and the properties and
/// methods of theirs the app's scripts read, call or wrap.
nonisolated extension SteamSurface {
    private static func global(_ name: String, _ use: String) -> Entry {
        Entry(.global, name, use, .global)
    }

    /// A property, or with `passes` a method the app calls with that many arguments.
    private static func member(_ name: String, _ use: String, passes: Int? = nil) -> Entry {
        Entry(.member, name, use, .identifier(passes: passes))
    }

    /// A field Steam's scripts never spell: the native half fills it in, or
    /// the app sends it and nothing in the page reads it.
    private static func unprobed(_ name: String, _ use: String, _ reason: String) -> Entry {
        Entry(.member, name, use, .unchecked(reason))
    }

    private static let nativeField = "filled in by the client's native half; Steam's scripts do not name it"

    static let globals: [Entry] = [
        global("App", "whether the client's UI has finished booting; the signed-in account"),
        global("appStore", "the library: every app's overview"),
        global("appDetailsStore", "a game's details: platforms, compatibility tool, shortcut fields"),
        global("collectionStore", "the library's collections; page readiness"),
        global("uiStore", "the library's two filters, for the Mac filter chip"),
        global("settingsStore", "client settings: Steam Play, rendering"),
        global("SteamUIStore", "the window store, the navigator and the running apps"),
        global("g_PopupManager", "every popup Steam has open, by name"),
        global("g_FriendsUIApp", "the friends list, chats, message sounds"),
        global("friendStore", "friends' names and states"),
        global("NotificationStore", "the toast Steam is about to show, for a Mac notification"),
        global("MainWindowBrowserManager", "the main window's current route"),
        global("webpackChunksteamui", "reaching Steam's webpack modules"),
    ]

    static let members: [Entry] = boot + library + details + filters + navigation + popups + modals
        + friends + notifications + clientAnswers + streamer + react

    private static let boot: [Entry] = [
        member("GetServicesInitialized", "whether the client's UI has finished booting", passes: 0),
        member("m_bIsInitialized", "whether the library has loaded, before reading shortcuts"),
        member("WindowStore", "page readiness; the main window instance"),
        member("MainWindowInstance", "page readiness; the main window's navigator"),
        member("allAppsCollection", "page readiness; the games asked of the compatibility service"),
        member("GetClientSetting", "reading Steam's rendering settings before Low Power Mode lowers them", passes: 1),
        member("settings", "the client's settings object"),
        member("bCompatEnabled", "whether Steam Play is on, for the macOS version choice"),
        member("PLATFORM", "the platform Steam's config reports, answered as linux to list Properties › Compatibility"),
    ]

    private static let library: [Entry] = [
        member("allApps", "listing the library"),
        member("GetAppOverviewByAppID", "one game's overview", passes: 1),
        member("appid", "an app's id"),
        member("display_name", "a game's name"),
        member("app_type", "telling games (1) from tools, software and soundtracks"),
        member("BIsModOrShortcut", "leaving mods and shortcuts out of the compatibility marks", passes: 0),
        member("BIsShortcut", "the library's Windows-program shortcuts", passes: 0),
        member("installed", "whether a game is installed"),
        member("local_per_client_data", "whether a game is installed on this computer"),
        member("per_client_data", "the other computers a game is installed on"),
        member("clientid", "telling this computer (\"0\") from the account's others"),
        member("client_name", "naming the computer a game is installed on"),
        unprobed("clientdata", "a game's update state", nativeField),
        member("size_on_disk", "sevo app list"),
        unprobed("minutes_playtime", "sevo app list", nativeField),
        member("steam_deck_compat_category", "Steam's Deck verdict, sent with the compatibility lookup"),
        member("display_status", "the status under a game's name; 8 is a Steam Cloud sync"),
        member("sort_as", "sorting the menu bar's library as Steam does"),
        member("rt_last_time_played", "the menu bar's recent games"),
        member("RunningApps", "what Steam believes is running, which gates every launch"),
    ]

    private static let details: [Entry] = [
        member("GetAppDetails", "a game's details", passes: 1),
        member("RequestAppDetails", "asking Steam to load a game's details", passes: 1),
        member("vecPlatforms", "whether a game has a macOS build (\"osx\")"),
        member("strCompatToolName", "the compatibility tool a game is mapped to"),
        member("strShortcutExe", "a shortcut's program"),
        member("strShortcutStartDir", "a shortcut's working folder"),
        member("strLaunchOptions", "a game's or shortcut's launch options"),
    ]

    private static let filters: [Entry] = [
        member("currentAppFilter", "the left list's filter, for the Mac filter chip"),
        member("collectionsAppFilter", "the grids' filter, for the Mac filter chip"),
        member("MatchesImpl", "wrapped so the Mac filter chip hides games", passes: 1),
        member("MatchesScoredImpl", "wrapped so the Mac filter chip hides games from search", passes: 1),
        member("bIsEmpty", "wrapped so a filter with the chip on is not skipped as empty"),
    ]

    private static let navigation: [Entry] = [
        member("Navigator", "the main window's navigator"),
        member("Home", "sending the main window to the library", passes: 0),
        member("m_lastLocation", "the game page the main window shows"),
    ]

    private static let popups: [Entry] = [
        member("m_mapPopups", "every popup by name"),
        member("GetPopups", "sevo app install: finding the license dialog", passes: 0),
        member("m_popup", "a popup's window object"),
        member("m_strName", "a popup's name"),
        member("m_strTitle", "a popup's title, which names a root menu"),
    ]

    private static let modals: [Entry] = [
        member("ModalManager", "finding modals whose popup is gone"),
        member("modals", "the modals Steam holds open"),
        member("legacy_popup_modals", "the modals shown in popups of their own"),
        member("RemoveModal", "dismissing a modal its popup left up", passes: 1),
        member("fnOnClose", "closing a popup modal the way Steam does"),
        member("Hide", "closing a menu through its own instance", passes: 0),
    ]

    private static let friends: [Entry] = [
        member("GetDefaultBrowserContext", "the context Steam opens friends windows in", passes: 0),
        member("m_DesktopApp", "the desktop friends app"),
        member("ShowChatUnreadMessages", "opening the oldest unread conversation", passes: 1),
        member("ShowPopupFriendsList", "opening the friends list", passes: 3),
        member("UIStore", "the friends UI's store"),
        member("ShowFriendChatDialogWhenReady", "opening a chat from a Mac notification", passes: 4),
        member("BPlayChatRoomNotificationSound", "whether a group message makes a sound", passes: 0),
        member("BPlayMessageSound", "whether a friend's message makes a sound", passes: 0),
        member("SettingsStore", "the friends settings"),
        member("FriendsSettings", "the friends settings"),
        member("bSounds_PlayMessage", "whether messages make a sound"),
        member("AudioPlaybackManager", "refusing Steam's own message sounds"),
        member("PlayAudioURL", "refusing Steam's own message sounds", passes: 1),
        member("BShowIncomingChatMessages", "refusing chat windows nobody asked for", passes: 0),
        member("GetFriendState", "a sender's name for a Mac notification", passes: 1),
        member("GetAccountID", "the one method of Steam's id object GetFriendState calls", passes: 0),
        member("GetPlayer", "a friend's own sound setting", passes: 1),
    ]

    private static let notifications: [Entry] = [
        member("CurrentToastSubscribableValue", "the toast Steam is about to show"),
        member("Subscribe", "hearing each toast", passes: 1),
        member("eType", "a toast's kind (8 a friend's message, 9 a group's); a launch option's type"),
        member("eSource", "where a toast came from"),
        member("notificationID", "a toast's id"),
        member("toObject", "a toast's payload as plain fields", passes: 0),
        member("steamid_sender", "who sent the message a toast is about"),
        member("game_name", "the game a toast is about"),
    ]

    /// Fields of what the client answers and of what Steam hands the calls
    /// the app answers.
    private static let clientAnswers: [Entry] = [
        member("strDescription", "a launch option's label"),
        member("strGameName", "the game a launch option names"),
        member("nIndex", "a launch option's index, handed back to ContinueGameAction"),
        member("bWaitingForUI", "whether a launch waits on the user"),
        member("strTaskName", "what a launch waits on"),
        member("rgApps", "the games the install wizard holds"),
        member("nAppID", "a game in the install wizard"),
        member("eInstallState", "the install wizard's page; 0 closed, 8 the license agreement"),
        member("eAppError", "the install wizard's error"),
        member("errorDetail", "the install wizard's error text"),
        member("currentAppID", "the game the install wizard is on"),
        member("unAppID", "the game whose process started or ended"),
        member("bRunning", "whether that game's process is running"),
        member("nFolderIndex", "a library folder's index"),
        member("strFolderPath", "a library folder's path"),
        member("strDriveName", "a library folder's drive"),
        member("strTitle", "a file dialog's title"),
        member("strInitialFile", "a file dialog's starting file"),
        member("rgFilters", "a file dialog's file types"),
        member("bSaveMode", "whether a file dialog saves"),
        member("bChooseDirectory", "whether a file dialog picks a folder"),
        member("flHorizontalScale", "the monitor's scale, answered to GetDefaultMonitorDimensions"),
        member("flVerticalScale", "the monitor's scale, answered to GetDefaultMonitorDimensions"),
        member("nFullWidth", "the monitor's size, answered to GetDefaultMonitorDimensions"),
        member("nFullHeight", "the monitor's size, answered to GetDefaultMonitorDimensions"),
        unprobed("nAvailableWidth", "the monitor's usable area, answered to GetDefaultMonitorDimensions", unread),
        unprobed("nAvailableHeight", "the monitor's usable area, answered to GetDefaultMonitorDimensions", unread),
        unprobed("nAvailableLeft", "the monitor's usable area, answered to GetDefaultMonitorDimensions", unread),
        unprobed("nAvailableTop", "the monitor's usable area, answered to GetDefaultMonitorDimensions", unread),
    ]

    /// What Streamer Mode reads to learn the names and pictures it hides.
    private static let streamer: [Entry] = [
        member("m_CurrentUser", "Streamer Mode: the signed-in account"),
        member("strAccountName", "Streamer Mode: the account name to hide"),
        member("strAccountBalance", "Streamer Mode: the wallet balance to hide"),
        member("strAccountBalancePending", "Streamer Mode: the pending balance to hide"),
        member("m_FriendsUIFriendStore", "Streamer Mode: the friends store's own cache"),
        member("m_self", "Streamer Mode: the signed-in player"),
        member("m_persona", "Streamer Mode: a player's persona"),
        member("m_strPlayerName", "Streamer Mode: a player's name"),
        member("m_strNickname", "Streamer Mode: a friend's nickname"),
        member("m_strAvatarHash", "Streamer Mode: a player's picture"),
        member("m_unAccountID", "Streamer Mode: a player's account id"),
        member("m_unGamePlayedAppID", "Streamer Mode: ordering friends as the list does"),
        member("m_ePersonaState", "Streamer Mode: ordering friends as the list does"),
        member("m_mapPlayerCache", "Streamer Mode: every player Steam has seen"),
        member("allFriends", "Streamer Mode: the friends list"),
        member("m_ChatStore", "Streamer Mode: group chats"),
        member("m_mapChatGroups", "Streamer Mode: group chats"),
        member("m_rgGroupMembersSummary", "Streamer Mode: a group's members"),
        member("m_groupMembers", "Streamer Mode: a group's members"),
        member("m_FriendStore", "Streamer Mode: looking up a group member"),
    ]

    /// React's own bookkeeping, which Steam's bundle carries.
    private static let react: [Entry] = [
        Entry(.member, "__reactFiber$", "reaching the component behind a DOM element", .text(["__reactFiber$"]), tokens: ["__reactFiber"]),
        member("memoizedProps", "reading a component's props: an app id, a menu's instance, the modal manager"),
    ]
}
