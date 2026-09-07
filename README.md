# Sevoflurane

**Steam for macOS, as a real Mac app. It runs Windows games, DirectX 12
included.**

Sevoflurane shows your Steam library in native Mac windows. The Windows
Steam client runs hidden inside a Wine bottle and does what it is good at:
downloads, installs, ownership, launching games. Everything you see and touch
is macOS.

> **Status: pre-release.** The core works: Steam's own interface in native
> windows, installs, launches, a supervisor that heals Steam's hangs, and a
> built-in engine that runs DirectX 12 games through Apple's Game Porting
> Toolkit. A first public build is being prepared. A cold start takes about a
> minute today.

The name is an anesthetic: delivered as vapor, known for a smooth and fast
induction. Its color code is yellow, and so is the app's accent.

## What it is

Steam's interface is a web app. Sevoflurane serves that web app into Mac
windows of its own. Every window Steam opens becomes a Mac window with the
right role: the library, menus, the friends list, chats, notifications, the
in-game overlay. The menu bar is the Mac menu bar. Notifications are Mac
notifications.

Games run through a Wine engine. The app ships its own, open-source engine,
[methylpentynol](https://github.com/kageroumado/methylpentynol). It carries
the changes that make Apple's DirectX 12 layer run on upstream Wine, plus
fixes for Steam and for Rosetta. CrossOver works as the engine too, and setup
recommends it: buying it funds the people who make Wine run on a Mac.

## What it can do that others cannot

"Others" means the usual way to play Steam games on a Mac: the Windows Steam
client running inside a Wine app such as CrossOver or Whisky.

| Capability | Sevoflurane | Steam inside a Wine app | What it means for you |
|---|:---:|:---:|---|
| Steam's interface in Mac windows | ✓ | — | Traffic lights, Mission Control, full screen, the macOS menu bar driving Steam's menus. No Windows-style window drawn by Wine. |
| Mac notifications | ✓ | — | A chat message is a macOS banner with the sender's avatar. Click it and the chat opens. The Windows toast never appears. |
| A menu-bar launcher | ✓ | — | Recent games launch from a popover in the menu bar. The big window need not open at all. |
| Heals Steam by itself | ✓ | — | The "a critical Steam component is not responding" hang is detected and repaired: restart, cache repair, crash-loop protection. Quitting the app takes the whole bottle down. |
| Every game is a Mac app | ✓ | — | Each game runs from its own app bundle with the game's name and icon. The Dock shows the game, not "wine". macOS Game Mode turns on when the game goes full screen. |
| Settings per game, no restart | ✓ | — | Window mode, upscaler, mouse and more are set per game. A change reaches the game at its next launch while Steam keeps running. |
| Upscaling built in | ✓ | — | The engine puts every frame on screen through its own Metal layer, so a game can be upscaled on the way: Lanczos, MetalFX, Anime4K or CuNNy, chosen per game. |
| Full-screen games in a window | ✓ | — | A game that insists on full screen, or on a fixed window size, runs in a resizable Mac window. The game never notices. |
| Mouse-look that feels like a mouse | ✓ | — | A game that takes the cursor to aim can get the mouse's own movement instead of the Mac's accelerated pointer. |
| Compatibility on every game page | ✓ | — | Where Steam shows its Deck badge, the game page shows a Mac verdict and an anti-cheat verdict, with sources: AppleGamingWiki, AreWeAntiCheatYet, ProtonDB. |
| RPG Maker games run natively | ✓ | — | A game built on NW.js runs as a real Mac process. Steam still counts playtime, and achievements still arrive. |
| A command line and an AI agent interface | ✓ | — | `sevo` manages and heals Steam from the terminal. The same verbs are an MCP server, so an AI agent can install a game or fix a stuck download. |
| DirectX 12 games | ✓ | ✓ | Apple's Game Porting Toolkit runs on the built-in engine and on CrossOver. |
| Open source | ✓ | varies | The app is MIT. The engine is LGPL, like Wine. |

## Graphics

A Windows game draws with Direct3D. On a Mac those calls must be translated
to Metal. Which translator a game gets is the biggest single lever on how it
runs. Settings › Graphics picks one for the bottle, and a game can override
it.

| Renderer | What it is | Choose it when |
|---|---|---|
| **D3DMetal** | Apple's Game Porting Toolkit: Direct3D 11 and **12** | The default. The only path for DirectX 12 and for MetalFX upscaling. |
| **DXMT** | Open-source Direct3D 10/11 straight to Metal ([3Shain/dxmt](https://github.com/3Shain/dxmt)) | DirectX 11 titles. Some run better here and some on D3DMetal. It is one switch to try. |
| **DXVK** | Direct3D 9 to 11 through Vulkan and MoltenVK | A game refuses to draw on either Metal path, or needs Direct3D 9. |
| **Automatic** | CrossOver's per-game database, then Wine's `wined3d` | You would rather trust their testing than choose. |

Apple's toolkit is fetched in-app through Apple's own sign-in. Releases and
betas sit side by side; the newest is used unless you pick another. DXMT and
DXVK versions can be added the same way. 32-bit games get Metal too.

## DirectX 12, measured

The built-in engine was run against Microsoft's DirectX-Graphics-Samples.
The samples were built on Windows with a frame-count exit and compared with
the same binaries on an RTX 4080 SUPER, using D3DMetal 4.0 beta 2. Of 35
comparable samples, 23 draw the reference image.

| Works | Does not |
|---|---|
| The HelloWorld set: window, triangle, texture, constant buffers, bundles, frame buffering | DirectX Raytracing, all four samples. The toolkit reports no raytracing tier. |
| Execute indirect, multithreading, predication queries, reserved resources, residency, small resources, depth bounds, dynamic indexing, n-body gravity | Variable Rate Shading. No tier is reported and the sample gives up. |
| Mesh shaders: meshlet render, cull, instancing | Mesh shaders: dynamic LOD draws the mesh as shards. |
| Full screen, linked-GPU samples on one adapter | Cross-GPU copy. One adapter is exposed. |
| | Pipeline state cache, generic programs, 11-on-12. They abort at the first Direct3D 12 call. |
| | HDR and SM6 wave intrinsics. They stop on their own error dialog. |

The toolkit reports feature level 12_2, resource binding tier 3, heap tier 2,
enhanced barriers, wave operations and mesh shaders, the same as the RTX
card. Shader Model is 6.6 against 6.8. Root signature is 1.1 against 1.2.
Tiled resources are tier 2 against 4. Conservative rasterization, sampler
feedback, double-precision shaders and raytracing are absent. A game that
needs those will say so. The rest of Direct3D 12 is there.

## Known limits

- **Games with kernel anti-cheat stay on Windows.** EasyAntiCheat, BattlEye
  and similar need a Windows kernel driver. This is Wine's boundary, and it
  is the same for every tool of this kind.
- **Everything under the app runs as x86_64 under Rosetta.** macOS 27 is the
  last release that carries Rosetta in full. The app itself is native.
- **Whether a given game runs is the engine's story.** The app promises the
  experience: the client always opens, the windows are Mac windows, failures
  recover. Check CrossOver's database and AppleGamingWiki for a title, or
  the compatibility strip on its game page.
- **DirectX 12 is measured on samples and played on one game.** The table
  above is the samples. Subnautica 2 (Unreal Engine 5) runs through Steam on
  the built-in engine. Numbers nobody measured are not quoted here.
- **.NET 4.8 is left out of the dependency installer** on purpose. winetricks
  marks it broken on several Wine versions.

## Requirements

macOS 26 or later on Apple silicon. Nothing else. CrossOver is optional.

## How it works

Two halves, both open source.

**The interface.** The Windows Steam client runs headless in a bottle.
Steam's interface only needs a `SteamClient` binding to work, so Sevoflurane
serves Steam's own web bundle into native `WKWebView`s with a shim. The
shim's calls are replayed into the client's real context over the Chrome
DevTools Protocol. Protobuf traffic is relayed around CDP through a socket
the client's own context opens. Every window Steam creates is adopted into an
`NSWindow` with the right role.

**The engine.** Upstream Wine 11.16 with wine-staging, built for x86_64, plus
one commit of changes: hosting Apple's D3DMetal, CrossOver's msync, the
Rosetta fixes for 32-bit games, the presenter that scales frames, per-game
environment files, GPU identity, and the fixes that make the Steam client
boot cleanly. The [engine repository](https://github.com/kageroumado/methylpentynol)
lists every change against upstream. The engine ships as a versioned tarball
behind a manifest, so it updates through the app.

## For developers

### Building

Xcode 26 or later. Open `Sevoflurane.xcodeproj` and build the `Sevoflurane`
scheme. The first run walks through setup: it creates the bottle, installs
Steam and signs in. After that the app starts the bottled client with CDP on
port 8765, boots Steam's interface through the in-process bridge, and
supervises from there.

Diagnostics: `sevo doctor`, the event log at `~/Library/Logs/Sevoflurane.log`,
Wine's own log at `~/Library/Logs/Sevoflurane-wine.log`.

### `sevo`, the command line

`swift build` produces `.build/debug/sevo`. `sevo install-cli` links it into
`/usr/local/bin`. One management surface for terminals and agents:

```
sevo doctor [--json]        environment diagnosis, one line per check
sevo status [--json]        engine · bottle · client · bridge · app
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

See `CONTRIBUTING.md`. Start with the fidelity rules. Most non-obvious bugs
here are a violation of one of them.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
