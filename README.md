# Sevoflurane

**English** · [简体中文](README.zh-CN.md)

Sevoflurane brings a Proton-like experience to Mac, running Windows and macOS games from the same Steam interface. Native WebKit windows replace Steam’s Wine-rendered Chromium UI, while Steam runs in the background with macOS notifications. Older games get resizable windows and upscaling.

<a href="https://kagerou.glass/get/sevoflurane?from=readme"><img src=".github/download.svg" alt="Download Sevoflurane for Mac" width="360" height="80"></a>

![Steam's library in a Mac window, filtered to the games that play on this Mac; a game's version menu offering its macOS and Windows versions; the macOS version open as its own app with its own Dock icon; Horizon Zero Dawn, a DirectX 12 Windows game, in a Mac window; a visual novel resized](.github/sevoflurane-film.avif)

## Highlights

- Run Windows and native Mac games from one library, choosing the version per game.
- Use Steam through WebKit windows while the Windows client runs in the background; receive its notifications through macOS.
- Resize older games and upscale them with Lanczos, MetalFX, Anime4K, or CuNNy.
- Give each game its own Dock icon and graphics settings.

<details>
<summary>Full feature list</summary>

- **Setup:** guided Steam installation; new or existing bottles; Dormison, CrossOver, and CrossOver Preview; fonts, legacy runtimes, Rosetta, and Game Porting Toolkit installation; background setup and `sevo setup`.
- **Steam:** Library, Store, Friends, chats, Big Picture, keyboard, and controller configuration in Mac windows; native menus, clipboard, launch-choice alerts, `steam://` links, and macOS notifications.
- **Personalization:** CSS styles with live reload, Streamer Mode, and Low Power Mode/Reduce Motion integration.
- **Compatibility:** per-version ratings from Sevoflurane runs, AppleGamingWiki, and ProtonDB; anti-cheat information; library medals, native-Mac markers, and a playable-on-this-Mac filter. Linux ratings are displayed separately from the Mac filter.
- **Launchers:** recent and installed games in the menu bar and Dock menu; per-launch or persistent renderer choices; Quick Launch for external programs.
- **Game windows (Dormison):** independent Dock icons, Game Mode, resizable fixed-resolution windows, Lanczos/MetalFX/Anime4K/CuNNy upscaling, live filters, frame-rate limits, and CPU/GPU/frame-time overlays.
- **Input and media:** Xbox/PlayStation controller input with rumble; DLSS through MetalFX on D3DMetal. Dormison adds raw mouse input, cursor confinement, native Win32 menus, CPU caps, and hardware H.264/HEVC decoding.
- **Native games:** macOS game installs and per-game version switching on supported engines; a game Steam for Mac already has installs from its copy without a download; optional handoff to Steam for Mac. Native NW.js games retain Steam playtime and achievements.
- **Game sessions:** display-awake holds, stuck-game termination, complete process cleanup, Steam reconnection, and Discord activity; Dormison also relays games’ own Discord integration.
- **External games:** Finder `.exe` launch and thumbnails, installer tracking, Quick Launch, non-Steam library entries, Steam Input, overlay, and run reports. Kernel-driver dependencies are reported.
- **HoYoverse:** install, update, resume downloads, and verify Genshin Impact, Honkai: Star Rail, and Zenless Zone Zero. Optional Genshin frame-rate unlocker is off by default because it modifies game memory.
- **Configuration:** searchable per-engine and per-game graphics, input, performance, DLL, and environment settings; known fixes with undo; dependency repair; Proton-style launch-option import.
- **Storage:** per-game and category sizes, cache/engine cleanup, external libraries, and sharing installed games across bottles with separate saves.
- **Recovery:** client watchdog, crash-loop detection, lost-wake recovery, orphan cleanup, helper/bottle repair, cache resets, and recovery guides. A running game survives a Sevoflurane crash; reopening reattaches.
- **Community:** opt-in run statistics with a payload preview, per-game verdicts and notes, engine/chip comparisons, and deletion of shared data.
- **Diagnostics:** run records, frame-time traces, logs, crash reports, per-game recording levels, redacted report sharing, Process Monitor, CPU-cap suggestions, and `sevo perf compare`.
- **Automation and updates:** CLI/MCP, idle-time app updates, engine/renderer update notices, and engine switching.
- [Detailed feature reference](REFERENCE.md#full-feature-list). Dormison-specific features require that engine.

</details>

## Notes

- [Game compatibility](https://kagerou.glass/sevoflurane/games/) · [Renderer choices and limits](REFERENCE.md#renderers).
- **Settings → About → Save Diagnostics…** collects a report. [CLI/MCP reference](REFERENCE.md#command-line) · [Contributing](CONTRIBUTING.md).
