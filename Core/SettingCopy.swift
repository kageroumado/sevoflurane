import Foundation

/// The words Settings › Engine and Settings › Games share for a setting both
/// can set: its title, the one line under its row, and what its (i) says.
nonisolated struct SettingCopy: Sendable {
    let title: String
    var caption = ""
    var help: SettingHelp?

    init(title: String, caption: String = "", help: SettingHelp? = nil) {
        self.title = InterfaceCopy.localized(title)
        self.caption = InterfaceCopy.localized(caption)
        self.help = help
    }
}

nonisolated extension SettingCopy {
    /// What each renderer is for, in the words ``Renderer/guidance`` holds:
    /// the popover Settings › Graphics and a game's Renderer row both open.
    static func renderers(_ available: [Renderer], footnote: String? = nil) -> SettingHelp {
        SettingHelp(
            title: "Choosing a renderer",
            summary: "These renderers translate Direct3D for macOS. Try another if a game looks wrong.",
            entries: available.map { .init(name: $0.label, text: $0.guidance) },
            footnote: footnote,
        )
    }

    static let windows = SettingCopy(
        title: "Resizable windows",
        caption: "A resizable window scales the game's picture to fit.",
        help: SettingHelp(
            title: "Resizable windows",
            summary: "A game draws at the size it chose. A resizable window scales that picture to "
                + "the window through the upscaler, and the game keeps believing in its own size.",
            entries: [
                .init(
                    name: WindowTreatment.off.label,
                    text: "Every window stays as the game makes it, and a full-screen game covers the screen.",
                ),
                .init(
                    name: WindowTreatment.fixed.label,
                    text: "A window the game locks to one size gets a resize handle, and its picture scales "
                        + "to fit. A full-screen game stays full screen.",
                ),
                .init(
                    name: WindowTreatment.window.label,
                    text: "Also, a full-screen game plays in a window you can move and resize, and still "
                        + "draws as if it filled the screen. Pick this to play a full-screen game in a window.",
                ),
                .init(
                    name: WindowTreatment.all.label,
                    text: "Every window with a title bar can be resized, the ones a game already lets you "
                        + "resize included: such a game keeps its size and is scaled like the rest, rather "
                        + "than redrawing at the new size. A full-screen game stays full screen.",
                ),
            ],
        ),
    )

    static let scaling = SettingHelp(
        title: "Upscaler and final filter",
        summary: "Two steps, in order, between the game's picture and the window.",
        entries: [
            .init(
                name: "Upscaler",
                text: "Enlarges the picture with a shader made for it: Anime4K and CuNNy for drawn "
                    + "art, by whole steps such as 2×, and MetalFX Spatial for 3D games. Off hands "
                    + "the picture to macOS, which stretches it softly. Final filter only uses "
                    + "no shader.",
            ),
            .init(
                name: "Final filter",
                text: "Fits what the upscaler made to the window's exact size: all of the resizing "
                    + "with no shader, the last few percent after one. Lanczos is sharp, "
                    + "Bilinear soft, Nearest keeps hard pixel edges.",
            ),
        ],
        footnote: "View › Upscaler in a running game's menu bar switches live.",
    )

    static let mouse = SettingCopy(
        title: "Movement",
        caption: "What a game gets while it holds the pointer for mouse-look.",
        help: SettingHelp(
            title: "Mouse movement",
            summary: "Applies while a game has taken the pointer, as a first-person camera does. "
                + "Menus and the desktop keep the Mac's pointer.",
            entries: [
                .init(
                    name: "macOS acceleration",
                    text: "The pointer's usual curve: a fast flick travels farther than a slow "
                        + "sweep of the same length.",
                ),
                .init(
                    name: "Linear (no acceleration)",
                    text: "The mouse's own movement, unshaped: the same sweep of the hand turns "
                        + "the camera the same amount at any speed. What shooters expect.",
                ),
            ],
        ),
    )

    static let modeset = SettingCopy(
        title: "Fake display-mode changes",
        caption: "A game that switches the screen's resolution gets a window instead.",
        help: SettingHelp(
            title: "Fake display-mode changes",
            summary: "Older games ask Windows to switch the display to 800 × 600 or 1024 × 768 and "
                + "draw full screen. A Mac display has no such modes. With this on the game is "
                + "told the switch happened, and its picture goes into a window that the "
                + "upscaler scales.",
        ),
    )

    static let nativeMenuBar = SettingCopy(
        title: "Menus in the menu bar",
        caption: "A program's own menus, such as Game and Help, move into the macOS menu bar, "
            + "and the strip in its window is hidden.",
        help: SettingHelp(
            title: "Menus in the menu bar",
            summary: "Windows programs draw a row of menus at the top of their window. With this "
                + "on, Dormison shows those menus in the macOS menu bar, where a shortcut such as Ctrl+N "
                + "works as ⌘N, and crops the row out of the window. A program with a View "
                + "menu of its own keeps it, and Sevoflurane's View menu is named Picture.",
            footnote: "New in this release, so it starts off. Applies from the program's next launch.",
        ),
    )

    static let fps = SettingCopy(
        title: "Frame rate counter",
        caption: "The frame rate at the top right of the game's window.",
        help: SettingHelp(
            title: "Frame rate counter",
            summary: "Counts the frames the engine put on screen, whichever renderer drew them. "
                + "Overlay detail sets how much it shows.",
            footnote: "View › Show Frame Rate (⌥⌘F) switches it while a game runs.",
        ),
    )

    static let overlayDetail = SettingCopy(
        title: "Overlay detail",
        caption: "What the frame rate counter shows while it is on.",
        help: SettingHelp(
            title: "Overlay detail",
            summary: "How much the frame rate counter shows. It appears when Frame rate counter is on.",
            entries: [
                .init(name: OverlayDetail.frameRate.label, text: "One number."),
                .init(
                    name: OverlayDetail.frameTime.label,
                    text: "A card with every frame of the last five seconds drawn at the time it took, "
                        + "so a hitch shows as a spike the average hides, and the 1 % low: the frame "
                        + "rate of the slowest one in a hundred frames of the last ten seconds.",
                ),
                .init(
                    name: OverlayDetail.system.label,
                    text: "The card with a row for the game's CPU use, the GPU's load, the Mac's power "
                        + "draw and its temperature.",
                ),
            ],
            footnote: "View › Overlay Detail switches it while a game runs, and ⌥⌘G picks the "
                + "frame time card. sevo perf report charts a whole run after it ends.",
        ),
    )

    static let frameRateLimit = SettingCopy(
        title: "Frame rate limit",
        caption: "Saves battery and fan noise. Works on Dormison.",
        help: SettingHelp(
            title: "Frame rate limit",
            summary: "Dormison holds each frame until its turn, so the game draws no more frames "
                + "than the limit and the Mac does less work for the same picture. It paces every "
                + "renderer, Metal and OpenGL alike, with the upscaler on or off. A limit the game reaches steadily also plays more evenly "
                + "than a rate that swings.",
            footnote: "View › Frame Rate Limit switches it while a game runs, and the frame rate "
                + "counter shows the limit beside the rate.",
        ),
    )

    static let hud = SettingCopy(
        title: "Performance HUD",
        caption: "Apple's overlay: frame time, GPU time and memory.",
    )

    static let cursorConfine = SettingCopy(
        title: "Keep the pointer in the window",
        caption: "During mouse-look the pointer stays off your other displays.",
    )

    static let build = SettingCopy(
        title: "Play in",
        caption: "Steam for Mac runs the macOS version, with the game installed there.",
        help: SettingHelp(
            title: "Sevoflurane or Steam for Mac",
            summary: "Steam sells this game for macOS too. Play can run it here or in Valve's Steam for Mac.",
            entries: [
                .init(
                    name: GameBuild.windows.label,
                    text: "Sevoflurane's Steam. On an engine that plays macOS versions, the game page's Version "
                        + "button picks macOS or Windows; otherwise this is the Windows version. Every setting "
                        + "on this page applies to the Windows version.",
                ),
                .init(
                    name: GameBuild.mac.label,
                    text: "The game's macOS version, started by Valve's Steam for Mac, which needs the game "
                        + "installed there. Play opens its install page when the game is not, and the settings "
                        + "on this page stay with the Windows version.",
                ),
            ],
        ),
    )

    static let retina = SettingCopy(
        title: "High-resolution mode",
        caption: "Games see the display's real pixel count. Older games draw tiny text and menus.",
        help: SettingHelp(
            title: "High-resolution mode",
            summary: "A Retina display has four pixels for every point macOS lays out. Windows "
                + "programs are told the point size by default, and the picture is scaled up.",
            entries: [
                .init(
                    name: "On",
                    text: "Games see every pixel, so a 5K display offers 5120 × 2880 in a game's "
                        + "resolution list. A program written before high-DPI displays draws "
                        + "its text, buttons and launcher at half the size.",
                ),
                .init(
                    name: "Off",
                    text: "Everything keeps a readable size, and the upscaler sharpens the result.",
                ),
            ],
            footnote: "One setting for the whole bottle, read by each game as it starts.",
        ),
    )

    static let tuning = SettingCopy(
        title: "Thread waiting",
        caption: "How long a game's threads look for work before they sleep.",
        help: SettingHelp(
            title: "Thread waiting",
            summary: "A game's threads hand work to each other thousands of times a second. "
                + "Putting a thread to sleep and waking it costs far more on macOS than on "
                + "Windows, so a thread can spin briefly first in case its wake-up is about to "
                + "arrive.",
            entries: [
                .init(name: "Standard", text: "A waiting thread sleeps at once, as Wine does it."),
                .init(
                    name: "Experimental",
                    text: "A thread spins for about two microseconds first, and stops doing so "
                        + "where that keeps failing. Hand-offs get up to ten times quicker; a "
                        + "game with more busy threads than the Mac has cores pays in "
                        + "processor time.",
                ),
                .init(
                    name: "Custom",
                    text: "Wait spin and Object spin count loop iterations of about 0.4 ns each: "
                        + "5200 is two microseconds, 0 is off. Wait spin covers a thread "
                        + "waiting on anything; Object spin covers a contended lock, event or "
                        + "semaphore. Back off stops the spinning on waits that keep missing.",
                ),
            ],
            footnote: "Measure with the frame rate counter. Most games show no difference.",
        ),
    )

    static let processors = SettingCopy(
        title: "Processors",
        caption: "Some older games start one worker thread per processor and keep them all busy; "
            + "fewer processors let them rest.",
        help: SettingHelp(
            title: "Processors",
            summary: "How many processors a game is told the Mac has. Games built on Unity 5 start "
                + "a worker thread for each one, and under Rosetta every worker keeps looking "
                + "for work instead of sleeping, so a Mac with many cores spends them all on "
                + "waiting.",
            entries: [
                .init(name: "All", text: "The game sees every processor, as it would on Windows."),
                .init(
                    name: "8 · 6 · 4",
                    text: "The game sees that many and starts that many workers. A game that uses "
                        + "most of the processor time and still stutters runs smoother with fewer.",
                ),
            ],
            footnote: "Measure with the frame rate counter and Activity Monitor.",
        ),
    )

    static let unifiedMemory = SettingCopy(
        title: "Unified memory",
        caption: "Experimental. Tells games the GPU shares the Mac's memory, so textures are written once.",
        help: SettingHelp(
            title: "Unified memory",
            summary: "A Mac has one pool of memory that the processor and the graphics chip both "
                + "use. Windows games expect a separate graphics card, so they copy every "
                + "texture twice: once to hand it over, once to store it. On a Mac both copies "
                + "land in the same memory.",
            entries: [
                .init(
                    name: "On",
                    text: "The game is told the truth (Direct3D 12 calls it UMA) and writes each "
                        + "texture once. Games that stream large scenes gain the most.",
                ),
                .init(
                    name: "If a game misbehaves",
                    text: "Wrong textures, or a game that stops at launch: turn it off for that "
                        + "game. Few games are tested on this path.",
                ),
            ],
            link: .init(
                title: "Microsoft on UMA in Direct3D 12",
                url: URL(string: "https://learn.microsoft.com/windows/win32/api/d3d12/ns-d3d12-d3d12_feature_data_architecture")!,
            ),
        ),
    )

    static let largeAddressAware = SettingCopy(
        title: "4 GB for 32-bit games",
        caption: "A 32-bit game may use 4 GB where Windows would give it 2.",
        help: SettingHelp(
            title: "4 GB for 32-bit games",
            summary: "A 32-bit program can address 4 GB, and Windows gives it the lower 2 GB unless "
                + "its file carries the Large Address Aware flag. Modded and texture-heavy "
                + "32-bit games run out of those 2 GB and crash. With this on every 32-bit game "
                + "gets all 4, flag or no flag.",
            entries: [
                .init(
                    name: "If a game misbehaves",
                    text: "A few old games assume addresses stay under 2 GB and crash above it: "
                        + "turn it off for that game.",
                ),
            ],
            link: .init(
                title: "Microsoft on the 4 GB address space",
                url: URL(string: "https://learn.microsoft.com/windows/win32/memory/4-gigabyte-tuning")!,
            ),
        ),
    )

    static let avx = SettingCopy(
        title: "Report AVX to games",
        caption: "Games that check for AVX at launch find it.",
        help: SettingHelp(
            title: "Report AVX to games",
            summary: "AVX and AVX2 are processor instructions many games since 2020 require. "
                + "Rosetta translates them either way; this makes it say so, which is what a "
                + "game's start-up check reads.",
            entries: [
                .init(
                    name: "If a game misbehaves",
                    text: "A game that picks a slower AVX code path because it is offered can run "
                        + "better with this off.",
                ),
            ],
        ),
    )

    static let environment = SettingHelp(
        title: "Environment",
        summary: "Variables the game starts with, by name: the DXVK_HUD=1 or WINEDLLOVERRIDES=… a fix "
            + "for a game often names.",
        entries: [
            .init(
                name: "Steam's launch options",
                text: "A line such as DXVK_HUD=1 %command% -windowed, the form Proton fixes are shared in, "
                    + "works too. Sevoflurane moves the variables ahead of %command% here, and Steam "
                    + "keeps %command% -windowed.",
            ),
            .init(
                name: "Over a setting",
                text: "A variable a setting above also writes takes that setting's place, and its row "
                    + "says which.",
            ),
            .init(name: "An empty value", text: "Removes the variable, for a game that misreads one."),
        ],
        footnote: "Settings › Engine holds the variables every game gets; a game's own win. A change applies "
            + "the next time the game starts.",
    )

    static let dllOverrides = SettingHelp(
        title: "DLL overrides",
        summary: "Wine ships its own version of most Windows libraries and prefers it. An override "
            + "changes that for one library.",
        entries: [
            .init(
                name: "Native, then built-in",
                text: "Use the copy the game or an installer brought, and Wine's where there is "
                    + "none. What a mod loader, ReShade or a Visual C++ runtime needs.",
            ),
            .init(name: "Built-in, then native", text: "Wine's copy first. Wine's usual order."),
            .init(name: "Native only · Built-in only", text: "One of them, with nothing to fall back to."),
            .init(name: "Disabled", text: "The library is not loaded at all."),
        ],
        footnote: "These are Wine's own overrides, the values winecfg's Libraries tab shows and edits: a "
            + "game's are stored under its program, the bottle's under every program. The "
            + "renderer's libraries (d3d9 to d3d12, dxgi) follow the Renderer setting, which wins.",
    )
}
