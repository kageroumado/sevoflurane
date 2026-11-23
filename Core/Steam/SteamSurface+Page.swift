import Foundation

/// What the injected scripts find in Steam's pages: webpack modules by their
/// text, class names, routes and links, settings and fixed values.
nonisolated extension SteamSurface {
    /// The longest module source the scripts look at when hunting a class map.
    static let classMapModuleLimit = 20000

    /// The compatibility strip reads only modules this short.
    static let deckStripModuleLimit = 4000

    static let classMaps: [Entry] = [
        Entry(
            .classMap, "the Deck compatibility strip's classes", "placing the Mac compatibility strip under a game page's tab bar",
            .classMap(signature: ["DeckVerifiedInfo"], limit: deckStripModuleLimit),
            tokens: ["DeckVerifiedInfo", "Container"],
        ),
        Entry(
            .classMap, "the Play button's classes", "the Install button's version mark and the ▾ beside it",
            .classMap(signature: ["PlayButtonContainer", "StreamingSelector"], limit: classMapModuleLimit),
            tokens: ["PlayButtonContainer", "StreamingSelector", "PlayButton", "ButtonChild", "ShowingStreaming"],
        ),
        Entry(
            .classMap, "the play bar's classes", "the play bar's Version entry",
            .classMap(signature: ["ActionSection", "GameStatsSection"], limit: classMapModuleLimit),
            tokens: [
                "ActionSection", "GameStatsSection", "GameStat", "GameStatIcon", "GameStatRight", "PlayBarLabel",
                "PlayBarDetailLabel", "ClickablePlayBarItem",
            ],
        ),
        Entry(
            .classMap, "the game page's compact button class", "the Version entry's button, like Cloud Status's",
            .classMap(signature: ["AppDetailsButton"], limit: classMapModuleLimit),
            tokens: ["AppDetailsButton"],
        ),
        Entry(
            .classMap, "the library search's classes", "the Mac filter chip beside the search field",
            .classMap(signature: ["AdvancedSearchContainer"], limit: classMapModuleLimit),
            tokens: ["AdvancedSearchContainer", "Container"],
        ),
        Entry(
            .classMap, "the left list's row classes", "a Mac verdict on every game's row",
            .classMap(signature: ["GameListEntryContainer"], limit: classMapModuleLimit),
            tokens: ["GameListEntryContainer"],
        ),
        Entry(
            .classMap, "the grid's tile classes", "a Mac verdict on every game's tile",
            .classMap(signature: ["LibraryItemBox"], limit: classMapModuleLimit),
            tokens: ["LibraryItemBox"],
        ),
        Entry(
            .classMap, "the library filter bar's classes", "the Mac filter chip in the filter bar",
            .classMap(signature: ["ViewFiltersBar"], limit: classMapModuleLimit),
            tokens: ["ViewFiltersBar", "Filters", "CheckboxWithImage", "Active"],
        ),
    ]

    /// The localization key of Properties › Compatibility, by which the
    /// component that lists the page is found.
    static let compatibilityPageKey = "#AppProperties_CompatibilityPage"

    static let markers: [Entry] = [
        Entry(
            .marker, compatibilityPageKey, "finding the component that lists Properties › Compatibility",
            .text(["\"\(compatibilityPageKey)\""]),
        ),
        Entry(
            .marker, "Found SteamDeckUnsupported set in AppFilter", "finding Steam's library filter class",
            .text(["Found SteamDeckUnsupported set in AppFilter"]),
        ),
        Entry(.marker, "[MobX]", "finding MobX's observable, for the filter chip's state", .text(["[MobX]"])),
        Entry(
            .marker, "the Linux test", "an exported function true only when PLATFORM is linux, found by calling it",
            .unchecked("found by calling Steam's exports under each platform, which needs a running page"),
            tokens: [],
        ),
        Entry(
            .marker, "went wrong while displaying", "recognizing Steam's error boundary in the page's console",
            .text(["went wrong while displaying", "Error Reference"]),
            tokens: ["went wrong while displaying", "Error Reference"],
        ),
    ]

    private static func cssClass(_ name: String, _ use: String) -> Entry {
        Entry(.cssClass, name, use, .cssClass)
    }

    static let cssClasses: [Entry] = [
        cssClass("TitleBar", "hiding Steam's window controls; the drag region"),
        cssClass("title-area", "hiding Steam's window controls; the drag region"),
        cssClass("title-bar-actions", "hiding a popup's window controls"),
        cssClass("window-controls", "hiding a popup's window controls"),
        cssClass("title-area-highlight", "left out of the drag region; hidden in windows with macOS chrome"),
        cssClass("singleWindowFocusBar", "hidden in windows with macOS chrome"),
        cssClass("currentUserContainer", "stretching the friends list's header under the macOS title bar"),
        cssClass("Gradient", "stretching the friends list's header gradient"),
        cssClass("FullModalOverlay", "finding a modal overlay its popup left up"),
        cssClass("DialogButton", "Steam's button look for the version menu's buttons"),
        cssClass("_DialogLayout", "Steam's button look for the version menu's buttons"),
        cssClass("Primary", "Steam's primary button; the license dialog's Accept"),
        cssClass("Secondary", "Steam's secondary button"),
        cssClass("Panel", "the play bar entry's panel; the left list's rows"),
        cssClass("Focusable", "the ▾ beside Install"),
        cssClass("SVGIcon_Download", "telling an Install button from a Play button"),
        cssClass("SVGIcon_Button", "the ▾ beside Install, drawn as Steam's"),
        cssClass("SVGIcon_FlatArrow", "the ▾ beside Install, drawn as Steam's"),
        cssClass("friend", "Streamer Mode: a friend's row"),
        cssClass("ingame", "Streamer Mode: a friend in a game"),
        cssClass("labelHolder", "Streamer Mode: a friend's name and game"),
        cssClass("gameIcon", "Streamer Mode: the game a friend plays"),
        cssClass("DesktopUI", "promised in the custom-style sample: the main window"),
        cssClass("WindowFocus", "promised in the custom-style sample: a focused window"),
        cssClass("DialogInput", "promised in the custom-style sample"),
        cssClass("DialogDropDown", "promised in the custom-style sample"),
        cssClass("DialogCheckbox", "promised in the custom-style sample"),
        cssClass("DialogToggle_Label", "promised in the custom-style sample"),
        cssClass("DialogHeader", "promised in the custom-style sample"),
        cssClass("ModalOverlayContent", "promised in the custom-style sample"),
        cssClass("SVGIcon_Settings", "promised in the custom-style sample"),
        cssClass("avatarHolder", "promised in the custom-style sample"),
        cssClass("avatarStatus", "promised in the custom-style sample"),
    ]

    /// The route of a game's page in the library, before the app id.
    static let libraryAppRoute = "/library/app/"

    static let urls: [Entry] = [
        Entry(
            .url, libraryAppRoute, "the game the main window shows",
            .text(["\"/library\"", "/app/${"]), tokens: ["\\/library\\/app\\/"],
        ),
        Entry(.url, "steam://store", "the Dock menu's Store", .text(["\"store\""])),
        Entry(.url, "steam://open/library", "the Dock menu's Library", .text(["\"open/library"])),
        Entry(.url, "steam://open/settings", "opening Steam's settings", .text(["\"open/settings"])),
        Entry(.url, "steam://open/bigpicture", "the Dock menu's Big Picture", .text(["\"open/bigpicture"])),
        Entry(.url, "steam://url/CommunityHome", "the Dock menu's Community", .text(["CommunityHome"])),
        Entry(.url, "steam://url/SteamWorkshopPage/", "opening a companion app's Workshop", .text(["SteamWorkshopPage"])),
        Entry(
            .url, "steam://uninstall/", "Settings › Storage's Uninstall",
            .unchecked("handled by the client's native half; Steam's scripts do not name it"),
        ),
        Entry(
            .url, "steam://rungameid/", "playing a macOS build in Steam for Mac",
            .unchecked("opened in Steam for Mac, a different client"),
        ),
        Entry(
            .url, "steam://install/", "installing a macOS build in Steam for Mac",
            .unchecked("opened in Steam for Mac, a different client"),
        ),
        Entry(
            .url, "steam://open/main", "asking macOS which app opens steam:// links",
            .unchecked("only the scheme is used, to ask LaunchServices for its handler"),
        ),
    ]

    /// A client setting the app reads and writes.
    enum Setting: String, CaseIterable, Sendable {
        case lowPerformanceMode = "library_low_perf_mode"
        case reduceMotion = "accessibility_reduce_motion"
        case smoothScroll = "smooth_scroll_webviews"
    }

    static let settings: [Entry] = Setting.allCases.map { setting in
        Entry(.setting, setting.rawValue, "lowered while macOS is in Low Power Mode, then restored", .text([setting.rawValue]))
    }

    /// The request through which Steam asks how a game should start.
    static let launchOptionRequest = "ShowLaunchOption"

    /// The start of the storage key a remembered launch option is kept under.
    static let rememberedLaunchOptionKey = "DefaultLaunchOption"

    /// Steam's `EResult` for a dismissed dialog.
    static let cancelledResult = 52

    /// The client id that names this computer in an install, uninstall or
    /// download call, as a JavaScript literal.
    static let thisClient = "\"0\""

    private static let nativeHalf = "sent by the client's native half; Steam's scripts do not name it"

    static let constants: [Entry] = [
        Entry(.constant, launchOptionRequest, "the game-action request the Mac's launch-option chooser answers", .unchecked(nativeHalf)),
        Entry(
            .constant, rememberedLaunchOptionKey, "the storage key of a remembered launch option, with Steam's own hash",
            .text(["\\\\DefaultLaunchOption\\\\", "4294967295+"]),
        ),
        Entry(
            .constant, "EResult 52", "rejecting a file dialog the way Steam reads as canceled",
            .unchecked("a number of the client's native half; Steam's scripts compare it by a minified name"), tokens: [],
        ),
        Entry(
            .constant, "this client is \"0\"", "the client an install, uninstall or download is for",
            .unchecked("a value; the calls that take it are checked for their argument count"), tokens: [],
        ),
        Entry(
            .constant, "overlay state Hidden is 0", "closing the overlay",
            .text(["Hidden=0]=\"Hidden\"", "Overlay=2]=\"Overlay\""]), tokens: [],
        ),
        Entry(
            .constant, "k_EWindowBringToFrontWithoutForcingOS", "showing a hover menu without taking focus (2)",
            .text(["WithoutForcingOS"]), tokens: [],
        ),
        Entry(
            .constant, "RunGame's launch source", "RunGame's third and fourth arguments, -1 and 100",
            .unchecked("values; Steam's own calls pass a minified constant"), tokens: [],
        ),
        Entry(
            .constant, "osx", "the platform name of a macOS build in vecPlatforms",
            .unchecked(nativeHalf), tokens: [],
        ),
        Entry(.constant, "RaiseJSException", "recognizing a refused call on the client's console", .unchecked(nativeHalf)),
        Entry(.constant, "Method call failed", "recognizing a refused call on the client's console", .unchecked(nativeHalf)),
        Entry(
            .constant, "#Steam_LaunchOption_Game", "a launch option's label, \"Play <game>\"",
            .unchecked("a localization key the client's native half sends"), tokens: ["Steam_LaunchOption_Game", "LaunchOption_"],
        ),
        Entry(
            .constant, "SteamClient.OpenVR", "recognizing the refusal of a SteamVR call, which a bottle has no SteamVR for",
            .text(["SteamClient.OpenVR."]), tokens: ["SteamClient.OpenVR", "OpenVR"],
        ),
        Entry(.constant, "ui_steam_message_old_smooth", "a message sound the Mac's notification replaces", .text(["ui_steam_message_old_smooth"])),
        Entry(.constant, "steam_chatroom_notification", "a message sound the Mac's notification replaces", .text(["steam_chatroom_notification"])),
        Entry(.constant, "steam_at_mention", "a message sound the Mac's notification replaces", .text(["steam_at_mention"])),
        Entry(
            .constant, "root menu names", "the five menus mirrored into the Mac's menu bar: Steam, View, Friends, Games, Help",
            .unchecked("the names are localization values, which the scripts hold as keys"), tokens: [],
        ),
    ]

    private static let storePage = "markup of store.steampowered.com, which the client's files do not hold"

    static let webPages: [Entry] = [
        Entry(.webPage, "deck-verified-results", "placing the compatibility strip above the store page's Deck block", .unchecked(storePage)),
        Entry(.webPage, "game_area_purchase", "the compatibility strip's second-choice place on a store page", .unchecked(storePage)),
        Entry(.webPage, "game_area_dlc_bubble", "leaving DLC without a compatibility strip", .unchecked(storePage)),
        Entry(.webPage, "game_area_soundtrack_bubble", "leaving soundtracks without a compatibility strip", .unchecked(storePage)),
        Entry(.webPage, "appHubAppName", "a game's name on its store page", .unchecked(storePage)),
        Entry(.webPage, "global_actions", "Streamer Mode: the account's avatar in the page header", .unchecked(storePage)),
        Entry(.webPage, "user_avatar", "Streamer Mode: the account's avatar in the page header", .unchecked(storePage)),
        Entry(.webPage, "account_pulldown", "Streamer Mode: the account name in the page header", .unchecked(storePage)),
        Entry(.webPage, "header_wallet_balance", "Streamer Mode: the wallet balance in the page header", .unchecked(storePage)),
        Entry(.webPage, "global_header", "promised in the custom-style sample", .unchecked(storePage)),
        Entry(.webPage, "game_area_purchase_game", "promised in the custom-style sample", .unchecked(storePage)),
    ]
}
