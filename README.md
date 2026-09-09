# Sevoflurane

**Play Windows Steam games on an Apple silicon Mac, with Steam's interface
in Mac windows.**

Browse your library, install games and chat with friends through Steam.
Sevoflurane uses Wine to run the Windows Steam client and compatible games
in the background.

> **Status: pre-release.** A first public build is being prepared.

Requires macOS 26.5 or later on Apple silicon.

## Get started

Build the app from source while the first public release is being prepared:

1. Open `Sevoflurane.xcodeproj` in Xcode with the macOS 26.5 SDK or later.
2. Choose your team under Signing & Capabilities and build the `Sevoflurane` scheme.
3. Open the app and follow setup to install Steam, then sign in.

Setup offers [Dormison](https://github.com/kageroumado/dormison), the free
Wine engine maintained with Sevoflurane. You can also use an installed copy
of CrossOver.

For DirectX 12 games, add Apple's Game Porting Toolkit during setup.
The download uses Apple's sign-in. CrossOver includes its own copy of
D3DMetal, the toolkit's graphics translator.

## Playing games

Steam's library, friends list and chats open in Mac windows, with the macOS
menu bar and notifications. Your library is also available from Sevoflurane's
menu bar icon.

With Dormison, you can:

- Give games their own Dock name and icon, with Game Mode support when the
  game is frontmost and fills the screen.
- Run full-screen or fixed-size games in resizable windows.
- Choose a renderer, upscaler and mouse behavior for each game.
- Run supported NW.js games, including RPG Maker MV and MZ games, with a
  macOS runtime while retaining Steam playtime and achievement support.

A background helper watches the Steam client for hangs and crashes. It can
restart the client, clear its web cache and repair its installation. If
recovery keeps failing, it stops retrying and reports the problem.

The helper owns the Windows side, so quitting and crashing are different
things. Quitting Sevoflurane quits Steam and everything in the bottle. If
Sevoflurane crashes or is force-quit while you are playing, the game keeps
running, and reopening Sevoflurane reattaches to the session you were in.

macOS asks you to approve the helper the first time Sevoflurane runs, in
System Settings › General › Login Items & Extensions. Without it Sevoflurane
cannot start Steam and says so.

## Game compatibility

Compatibility varies by game. Game pages show Mac and anti-cheat reports
from AppleGamingWiki, AreWeAntiCheatYet and ProtonDB, with links to the
sources. ProtonDB reports describe Linux compatibility; the badge details
say when Mac testing is unavailable.

Games or online modes that require Windows kernel anti-cheat cannot run
through Wine. A game's offline mode may still work.

The Windows engine runs under Rosetta. Sevoflurane itself is native on
Apple silicon.

## Graphics and game settings

Settings › Graphics chooses the default graphics translator. A game's
renderer can also be set from its menu in the menu bar library. Settings ›
Games has per-game window, upscaler, filter and mouse controls.

| Renderer | Supports | Use |
|---|---|---|
| **D3DMetal** | Direct3D 11 and 12 through Apple's Game Porting Toolkit | Required for DirectX 12. Install the toolkit when using Dormison. |
| **DXMT** | Direct3D 10 and 11 through Metal | Dormison's default before D3DMetal is installed. |
| **DXVK** | Direct3D 9 to 11 through Vulkan and MoltenVK | An option for DirectX 9 games, or when a Metal renderer has problems. |
| **Automatic** | CrossOver's per-game choices, with Wine's renderer as fallback | Uses CrossOver's database when running CrossOver. |
| **Wine built-in** | Wine's `wined3d` renderer | Another option for games that have trouble with the other renderers. |

Toolkit releases and betas can be installed side by side. The newest is
selected unless you choose another. DXMT and DXVK versions can also be
installed separately.

Dormison's presenter can upscale games with Lanczos, MetalFX or shader
packages such as Anime4K and CuNNy. Window, upscaler and mouse settings take
effect at the next game launch when the engine supports per-game
configuration files. Engines without that support need a Steam restart
for inherited settings.

Launch from the menu bar to apply renderer changes. Sevoflurane can stage
renderer files while Steam stays open; engine and msync changes require a
restart. Changes to the selected DXMT or DXVK version apply after Steam
restarts.

See [Dormison's testing notes](https://github.com/kageroumado/dormison#directx-12-testing)
for sample results and their limits.

## Reporting a problem

**Settings › About › Save Diagnostics…** saves a ZIP containing logs,
a `sevo doctor` report, engine details, Steam's own logs and recent crash
reports. Review the contents before sharing; logs and file paths can identify
your account. You can also run `sevo diag` from the terminal.

The main logs are `~/Library/Logs/Sevoflurane.log` and
`~/Library/Logs/Sevoflurane-wine.log`. The Wine log always records errors and
exceptions, so a game that exits on its own still leaves a trail; Settings ›
Engine › *Log every library a game loads* adds exception traces and each library load when that is
not enough. `sevo runs` lists what every launch ran on and how it ended.

Use the [issue templates](https://github.com/kageroumado/sevoflurane/issues/new/choose)
to report a problem. See [CONTRIBUTING.md](CONTRIBUTING.md) for debugging
and contribution instructions.

## Command line

`swift build` produces `.build/debug/sevo`. Run
`.build/debug/sevo install-cli` to link that executable into `/usr/local/bin`.

Start with `sevo doctor` to check the installation or `sevo status` to
inspect the running client. Use `--help` on a command for its arguments
and output options.

```text
sevo doctor [--json]
sevo setup [--engine E]
sevo status [--json]
sevo diag [--no-steam-logs]
sevo client start|stop|restart|update|pin|unpin
sevo recover [--deep]
sevo app list|info|launch|terminate|install|verify|uninstall|compat|config
sevo engine list|install [--file TARBALL]|use
sevo bottle config <key> [value]
sevo shaders list|install|remove
sevo downloads status|pause|resume|throttle KBPS
sevo run PROGRAM [ARGS]
sevo eval 'JS'
sevo cdp 'JS' [TARGET]
sevo logs [--tail N] [-f] [--wine]
```

`sevo recover --deep` adds web-cache removal and client repair.
The report carries Steam's own bootstrap, connection, webhelper,
game-process and console logs from the bottle; `sevo diag --no-steam-logs`
leaves them out.

Exit codes are 0 for success, 1 for an operation failure, 2 for an invalid
invocation, 3 for an incomplete installation and 4 for an unreachable
client. When the app is running, client lifecycle commands go through
its supervisor.

### MCP

`sevo mcp` provides a stdio MCP server. Its tools cover diagnostics,
client recovery, library queries, game installation and launch, downloads
and logs. It also exposes `sevo://status`, `sevo://doctor`, `sevo://log`
and `sevo://library` resources.

```json
{ "mcpServers": { "sevoflurane": { "command": "sevo", "args": ["mcp"] } } }
```

`eval_js` is exposed only with `SEVO_MCP_ALLOW_EVAL=1` in the server's environment.

## How it works

The Windows Steam client runs in a Wine bottle: a directory containing
its Windows files and settings. Sevoflurane loads Steam's web interface
into `WKWebView`s and connects its `SteamClient` calls to the client
through the Chrome DevTools Protocol on port 8765.

Protobuf traffic uses a separate socket opened by the client's context.
Sevoflurane assigns Steam windows roles such as library, chat, menu and
overlay, then hosts them in macOS windows.

Dormison supplies the Wine changes needed for D3DMetal, msync, 32-bit
games under Rosetta, Steam startup and the Metal presenter. CrossOver
and CrossOver Preview can also serve as engines.

### Source layout

- `Sevoflurane/` — the app. `Web/` hosts Steam's interface and windows;
  `Bridge/` connects pages to the client; `Setup/` handles installation;
  `App/` contains supervision, logging and the menu bar; `Support/`
  contains engine, bottle and game configuration code.
- `Sevo/` and `Package.swift` — the CLI and MCP server, compiled with
  shared lifecycle, CDP and provisioning sources from the app.
- `SevofluraneTests/` — the test bundle.
- `Tools/` — shader packaging, debugging and performance tools.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
