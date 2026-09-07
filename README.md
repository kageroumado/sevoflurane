# Sevoflurane

**Steam for macOS, as a real Mac app. It runs your Windows Steam games,
DirectX 12 included.**

Steam's own interface opens in Mac windows. Games install and launch as they
do anywhere. The Windows Steam client that makes this possible runs hidden
inside a Wine bottle, and Sevoflurane keeps it running.

> **Status: pre-release.** A first public build is being prepared.

The name is an anesthetic: delivered as vapor, known for a smooth and fast
induction. Its color code is yellow, and so is the app's accent.

## What it does

Steam's interface is a web app. Sevoflurane serves that web app into Mac
windows of its own and replays every call it makes into the real Steam client
running in the bottle. Every window Steam opens becomes a Mac window with the
right role: the library, menus, the friends list, chats, notifications, the
in-game overlay. The menu bar is the Mac menu bar. Notifications are Mac
notifications. When Steam's own component hangs after an update, the app
repairs it before you see anything.

Games run through a Wine engine. The app ships its own,
[Dormison](https://github.com/kageroumado/dormison): upstream Wine with the
changes that make Apple's DirectX 12 layer run on it, CrossOver's msync, the
Rosetta fixes for 32-bit games, an upscaling presenter, and the fixes that
make the Steam client boot cleanly. CrossOver works as the engine too, and
setup recommends it: buying it funds the people who make Wine run on a Mac.

## Compared with the other ways to play

| | Sevoflurane | Steam inside a Wine app | Steam's own Mac app |
|---|:---:|:---:|:---:|
| Plays Windows Steam games on a Mac | ✓ | ✓ | Mac-native games only |
| Nothing else to buy or install | ✓ | A Wine app, paid or free | ✓ |
| Looks and behaves like a Mac app | ✓ | — | ✓ |
| Setup is one window | ✓ | — | ✓ |
| Keeps working after Steam updates | ✓ | — | ✓ |
| DirectX 12 games | ✓ | With CrossOver | — |
| Each game is its own app in the Dock, with Game Mode | ✓ | — | ✓ |
| Mac notifications for messages and friends | ✓ | — | ✓ |
| Launch a game from the menu bar | ✓ | — | — |
| Settings per game, applied without restarting Steam | ✓ | — | — |
| Full-screen games in a resizable window | ✓ | — | — |
| Upscaling built in | ✓ | — | — |
| Mouse-look that feels like a mouse | ✓ | — | — |
| Mac and anti-cheat verdicts on every game page | ✓ | — | — |
| RPG Maker games run as native Mac processes | ✓ | — | — |
| A command line, and an interface for AI agents | ✓ | — | — |
| Free and open source | ✓ | Varies | Free |

"Steam inside a Wine app" is the Windows Steam client running inside CrossOver,
Whisky and the like, drawing its own Windows-style window. What each row means:

- **Looks and behaves like a Mac app.** Traffic lights, Mission Control, full
  screen, the macOS menu bar driving Steam's menus, Retina sharpness.
- **Setup is one window.** It creates the bottle, installs Steam and signs you
  in. Apple's DirectX 12 toolkit is fetched through Apple's own sign-in.
- **Keeps working after Steam updates.** The "a critical Steam component is
  not responding" hang is detected and repaired: restart, cache repair,
  crash-loop protection. Quitting the app takes the whole bottle down.
- **Each game is its own app.** Each game runs from an app bundle with its
  name and icon. The Dock shows the game. macOS Game Mode turns on when it
  goes full screen.
- **Settings per game.** Window mode, upscaler, mouse and renderer are set per
  game and reach it at its next launch while Steam keeps running.
- **Upscaling built in.** The engine puts every frame on screen through its
  own Metal layer, so a game is upscaled on the way: Lanczos, MetalFX, Anime4K
  or CuNNy, per game.
- **Full-screen games in a window.** A game that insists on full screen, or on
  a fixed window size, runs in a resizable Mac window. The game never notices.
- **Mouse-look.** A game that takes the cursor to aim gets the mouse's own
  movement instead of the Mac's accelerated pointer.
- **Verdicts on every game page.** Where Steam shows its Deck badge, the game
  page shows a Mac verdict and an anti-cheat verdict, with sources:
  AppleGamingWiki, AreWeAntiCheatYet, ProtonDB.
- **RPG Maker games.** A game built on NW.js runs as a real Mac process. Steam
  still counts playtime, and achievements still arrive.
- **A command line and an agent interface.** `sevo` manages and heals Steam
  from the terminal. The same verbs are an MCP server, so an AI agent can
  install a game or fix a stuck download.

The app is native on Apple silicon and drives whichever engine is installed:
Dormison, CrossOver, and CrossOver's ARM64 build once it hosts DirectX 12.

## Graphics

A Windows game draws with Direct3D. On a Mac those calls are translated to
Metal, and which translator a game gets is the biggest single lever on how it
runs. Settings › Graphics picks one for the bottle; a game can override it.

| Renderer | What it is | Choose it when |
|---|---|---|
| **D3DMetal** | Apple's Game Porting Toolkit: Direct3D 11 and **12** | The default. The only path for DirectX 12 and for MetalFX upscaling. |
| **DXMT** | Open-source Direct3D 10/11 straight to Metal ([3Shain/dxmt](https://github.com/3Shain/dxmt)) | DirectX 11 titles. Some run better here and some on D3DMetal. It is one switch to try. |
| **DXVK** | Direct3D 9 to 11 through Vulkan and MoltenVK | A game refuses to draw on either Metal path, or needs Direct3D 9. |
| **Automatic** | CrossOver's per-game database, then Wine's `wined3d` | You would rather trust their testing than choose. |

Toolkit releases and betas sit side by side; the newest is used unless you
pick another. DXMT and DXVK versions can be added the same way. 32-bit games
get Metal too.

DirectX 12 was measured on Microsoft's own samples against an RTX 4080 SUPER:
23 of 35 comparable samples draw the reference image. The full table, and
everything the engine changes in Wine, is in the
[Dormison README](https://github.com/kageroumado/dormison#directx-12-measured).

## Good to know

- **Games with kernel anti-cheat stay on Windows.** EasyAntiCheat, BattlEye
  and similar need a Windows kernel driver. The game page says so before you
  install.
- **The engine runs under Rosetta.** macOS 27 is the last release that carries
  Rosetta in full. The app itself is native.
- **Requirements.** macOS 26 or later on Apple silicon. CrossOver is optional.

## For developers

### Building

Xcode 26 or later. Open `Sevoflurane.xcodeproj` and build the `Sevoflurane`
scheme. The first run walks through setup: it creates the bottle, installs
Steam and signs in. After that the app starts the bottled client with CDP on
port 8765, boots Steam's interface through the in-process bridge, and
supervises from there.

Diagnostics: **Settings › About › Save Diagnostics…** writes a zip with the
logs, a `sevo doctor` report and the engine's identity. `sevo diag` does the
same from the terminal. The logs are `~/Library/Logs/Sevoflurane.log` and
`~/Library/Logs/Sevoflurane-wine.log`.

### `sevo`, the command line

`swift build` produces `.build/debug/sevo`. `sevo install-cli` links it into
`/usr/local/bin`. One management surface for terminals and agents:

```
sevo doctor [--json]        environment diagnosis, one line per check
sevo status [--json]        engine · bottle · client · bridge · app
sevo diag [--steam-logs]    the report zip for a bug report
sevo client start|stop|restart|update|pin|unpin
sevo recover [--deep]       the wedge playbook; --deep adds cache purge and repair
sevo app list|info|launch|terminate|install|verify|uninstall|compat|config
sevo engine list|install|use
sevo bottle config <key> [value]
sevo shaders list|install|remove
sevo downloads status|pause|resume|throttle KBPS
sevo run PROGRAM [ARGS]     one Windows program in the bottle, under the game's engine
sevo eval 'JS' · sevo cdp 'JS' [TARGET] · sevo logs [--tail N] [-f] [--wine]
```

`--json` everywhere. Exit codes: 0 ok · 1 failed · 3 not provisioned · 4
client unreachable. When the app is running, verbs that change state go
through its supervisor, so the restart ladder has one owner.

### MCP: ask your agent to fix your Steam

`sevo mcp` is a stdio MCP server with the same verbs as typed tools, plus
`sevo://status`, `sevo://doctor`, `sevo://log` and `sevo://library`
resources.

```json
{ "mcpServers": { "sevoflurane": { "command": "sevo", "args": ["mcp"] } } }
```

"Why won't Steam start", "install Hades and launch it", "my download is
stuck" all work from a chat. `eval_js` is exposed only with
`SEVO_MCP_ALLOW_EVAL=1` in the server's environment.

### How the interface works

The Windows Steam client runs headless in the bottle. Steam's interface needs
only a `SteamClient` binding, so Sevoflurane serves Steam's own web bundle
into native `WKWebView`s with a shim. The shim's calls are replayed into the
client's real context over the Chrome DevTools Protocol. Protobuf traffic is
relayed around CDP through a socket the client's own context opens. Every
window Steam creates is adopted into an `NSWindow` with the right role.

### Layout

- `Sevoflurane/` — the app (Swift 6). `Web/` hosts Steam's interface and
  windows, `Bridge/` is the page-to-client bridge, `Setup/` the first-run
  assistant, `App/` supervision, logging and the menu bar, `Support/` bottle
  paths, engines and subprocesses, `Resources/` the shim, licenses and the
  NW.js glue.
- `Sevo/` + `Package.swift` — the `sevo` CLI and MCP server. They compile the
  app's own lifecycle and CDP sources, so the two cannot drift.
- `SevofluraneTests/` — the test bundle. `Tools/` — the shader package
  builder and performance scripts. `Site/` — the landing page.

### Contributing

See `CONTRIBUTING.md` for the fidelity rules, the issue templates and what a
pull request is expected to say about how it was made.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
