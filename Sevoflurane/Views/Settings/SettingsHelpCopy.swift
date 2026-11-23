import Foundation

/// What the (i) says on the rows the panes write by hand. A catalog setting's
/// help is in ``SettingCopy``.
extension SettingHelp {
    // MARK: - General

    static let gamesFolder = SettingHelp(
        title: "Games folder in the Dock",
        summary: "A folder beside the Dock’s other folders that holds every game that has run: each "
            + "under its own icon, the last played on top. A click on a game starts it.",
        entries: [
            .init(
                name: "Grid, fan, or list",
                text: "Right-click the folder in the Dock to choose how it opens.",
            ),
        ],
    )

    static let compatibilityStrip = SettingHelp(
        title: "Mac compatibility strip",
        summary: "A strip on each game’s library and store page says how the game runs on a Mac, "
            + "whether it has a macOS version, and what its anti-cheat does.",
        entries: [
            .init(
                name: "In the library",
                text: "Every game gets a badge, and the Apple filter keeps only the games that play on this Mac.",
            ),
            .init(name: "Before an install", text: "Install warns before a game known to fail."),
            .init(
                name: "Where the verdicts come from",
                text: "Runs shared by Sevoflurane’s own players come first, where there are enough of them.",
            ),
        ],
    )

    static let steamForMac = SettingHelp(
        title: "Steam for Mac",
        summary: "With this on, a game that has a macOS version gets a Play in setting of its own, "
            + "which can hand that version to Valve’s Steam for Mac.",
        entries: [
            .init(
                name: "What Steam for Mac needs",
                text: "Its own sign-in, and the game installed there.",
            ),
            .init(name: "Off", text: "macOS versions install and play in Sevoflurane’s Steam."),
        ],
    )

    static let customStyle = SettingHelp(
        title: "Style Steam with CSS",
        summary: "Every CSS file in the Styles folder styles Steam’s windows, in name order. "
            + "Saving a file restyles them right away.",
        entries: [
            .init(
                name: "Class names",
                text: "Most of Steam’s class names change with each Steam update. .DesktopUI, .TitleBar, "
                    + "the .Dialog classes, the .SVGIcon_ icons, and ARIA roles stay the same; "
                    + "README.css in the folder lists them.",
            ),
        ],
    )

    static let streamerMode = SettingHelp(
        title: "Streamer Mode",
        summary: "For recording and streaming. Every Steam window shows the display name and avatar "
            + "set here in place of yours, and hides your wallet balance.",
        entries: [
            .init(name: "Friends", text: "Appear as AI models such as Claude, ChatGPT, and Gemini."),
        ],
    )

    static let shareRuns = SettingHelp(
        title: "Share run statistics",
        summary: "After a game closes, its frame rate, resolution, engine, and settings go to the public "
            + "Sevoflurane game database with your Mac’s model and chip.",
        entries: [
            .init(name: "Privacy", text: "Nothing names you, your Mac, or your account."),
        ],
    )

    static let usageCount = SettingHelp(
        title: "Count this Mac",
        summary: "Counts how many people use Sevoflurane. On each day you use it, one anonymous "
            + "check-in is sent.",
        entries: [
            .init(
                name: "What a check-in holds",
                text: "Sevoflurane’s version and build; the macOS version; whether the Mac is Apple "
                    + "silicon or Intel, its chip family, and its memory size rounded to a common one; "
                    + "your first language; the date; and how many of the last 7 days you used it.",
            ),
            .init(
                name: "What ties them together",
                text: "An install number made on this Mac for this purpose alone, a running count of "
                    + "its messages, and a signature from a key that never leaves this Mac.",
            ),
            .init(
                name: "What it leaves out",
                text: "Which games or programs you run. Nothing in it names you or your account.",
            ),
            .init(
                name: "Crash reports",
                text: "Adds a report when Sevoflurane itself crashes, with your name, your Mac’s name, "
                    + "and folder paths removed. A game’s crash is sent only from the crash prompt.",
            ),
            .init(name: "Off", text: "Deletes everything this Mac sent."),
        ],
    )

    // MARK: - Graphics

    static let reportedGPU = SettingHelp(
        title: "GPU reported to games",
        summary: "Some games check the graphics card’s name or driver before they start, and refuse "
            + "one they do not know. This sets what they are told. Speed still depends on your Mac.",
        entries: [
            .init(
                name: "Your Mac’s chip",
                text: "What the DirectX 11 and 12 renderers report by default. Wine’s built-in renderer "
                    + "reports its own card.",
            ),
            .init(name: "NVIDIA", text: "Passes most GPU and driver checks."),
            .init(name: "AMD", text: "Try this if a game rejects the NVIDIA card."),
        ],
    )

    static let upscalerPackages = SettingHelp(
        title: "Upscalers",
        summary: "Extra upscalers for games drawn at low resolution: pixel art, anime, visual novels. "
            + "MetalFX and the final filter are built in.",
        entries: [
            .init(
                name: "Choosing one",
                text: "The Upscaler setting picks one for every game, and each game can pick its own.",
            ),
            .init(
                name: "While a game runs",
                text: "View › Upscaler in its menu bar switches it live.",
            ),
        ],
    )

    // MARK: - Engine

    static let engineFile = SettingHelp(
        title: "Engine from a file or folder",
        summary: "Installs Dormison from disk, for a Mac the release feed does not reach or an engine "
            + "built here. The engine joins the Engine menu, and Switch decides when it runs.",
        entries: [
            .init(name: "A tarball", text: "Sevoflurane checks the .sig file beside it."),
        ],
    )

    static let knownFixes = SettingHelp(
        title: "Apply known fixes automatically",
        summary: "The first time a game starts, the settings the fix list names for it are set where "
            + "the game has none of its own.",
        entries: [
            .init(name: "Undo", text: "The game’s own settings show each one with an undo."),
        ],
    )

    // MARK: - Games

    static let steamLibrary = SettingHelp(
        title: "Show in Steam’s library",
        summary: "Listed as a non-Steam game, the program starts from Steam’s library and Big Picture, "
            + "with Steam Input and the overlay.",
        entries: [
            .init(name: "What it keeps", text: "The settings, Dock tile, and run records it has here."),
        ],
    )

    static let dockTile = SettingHelp(
        title: "Keep in Dock",
        summary: "The game’s own icon stays in the Dock, where a click starts it.",
        entries: [
            .init(
                name: "While the game runs",
                text: "Right-clicking its Dock icon offers the same under Options.",
            ),
            .init(
                name: "Before the first launch",
                text: "The game gets its icon at its first launch; after that it can stay.",
            ),
        ],
    )

    static let fpsUnlocker = SettingHelp(
        title: "Unlocker",
        summary: "Genshin holds itself to 60 fps. An unlocker that starts beside the game lifts that "
            + "to the chosen frame rate.",
        entries: [
            .init(
                name: "Sevoflurane’s own",
                text: "The engine carries genshin-fps-unlock’s unlocker (MIT). Switched on, it starts "
                    + "30 seconds after the game’s process appears.",
            ),
            .init(
                name: "Another unlocker",
                text: "Choose one, such as unlockfps_nc.exe, to use it instead.",
            ),
        ],
    )

    // MARK: - HoYoverse

    static let hoyoGames = SettingHelp(
        title: "HoYoverse games",
        summary: "Sevoflurane installs and updates these games from the servers HoYoPlay uses.",
        entries: [
            .init(
                name: "Updates",
                text: "A patch when the installed build is recent enough, and the changed files otherwise.",
            ),
            .init(
                name: "Honkai: Star Rail",
                text: "Kept up to date, but it does not start under Wine, so it is not added to Quick Launch.",
            ),
        ],
    )

    // MARK: - Diagnostics

    static let debugMode = SettingHelp(
        title: "Debug mode",
        summary: "One switch for reproducing a bug: it sets everything a report needs, "
            + "and takes it all off again when it ends.",
        entries: [
            .init(
                name: "What it records",
                text: "Every library a game loads, the renderer’s own errors in a file of "
                    + "their own, and how each frame reached the screen.",
            ),
            .init(
                name: "How it differs from the level",
                text: "The level is kept and costs little. Debug mode costs speed and disk, "
                    + "so it lives only as long as this session.",
            ),
        ],
        footnote: "Also in the menu bar popover, under the … button.",
    )

    static let wineLog = SettingHelp(
        title: "Log every library a game loads",
        summary: "~/Library/Logs/Sevoflurane-wine.log always records errors. With this on it also "
            + "records every exception and library load, so the log grows quickly.",
    )

    static let runReports = SettingHelp(
        title: "Run reports",
        summary: "Each report holds the run’s record, Wine’s exception trail, the game’s own crash logs, "
            + "and Steam’s, with paths, account names, and Steam ids taken out.",
        entries: [
            .init(
                name: "Limits",
                text: "Each limit is enforced as files are written; the oldest goes first.",
            ),
        ],
    )

    static let diagnosticsArchive = SettingHelp(
        title: "Archive on your Desktop",
        summary: "Logs, system details, and recent crash reports, saved as a ZIP file on your Desktop. "
            + "Your name, file paths, and Steam ids are taken out.",
        entries: [
            .init(name: "1. Before you launch the game", text: "Set Record to Diagnostics."),
            .init(
                name: "2. After the game loads",
                text: "Play for at least a minute in an area you can return to.",
            ),
            .init(
                name: "3. To test a setting",
                text: "Change one value and play the same area twice with each.",
            ),
            .init(name: "4. When the problem occurs", text: "Save the archive."),
            .init(name: "5. When you are done", text: "Set Record back to Standard."),
        ],
        footnote: "In Terminal, sevo diag --help shows these steps, and sevo perf compare measures a "
            + "setting’s effect.",
    )
}
