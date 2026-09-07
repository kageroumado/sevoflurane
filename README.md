# Sevoflurane

**Steam for macOS, as a real Mac app. It runs DirectX 12 games.**

Your Steam library opens in native windows with the macOS menu bar, Retina
sharpness, and macOS notifications. The Windows Steam client that makes this
possible runs invisibly in a Wine bottle. Steam keeps doing what it is good at
(downloads, installs, ownership, launching games). Everything you see and
touch is macOS.

> **Status: pre-release.** The core works: Steam's own interface in native
> windows, installs, launches, a supervisor that heals Steam's hangs, and a
> built-in engine that runs DirectX 12 games through Apple's Game Porting
> Toolkit. It is being hardened for a first public build. Cold start takes
> about a minute today.

Named after the anesthetic: delivered as vapor, known for a smooth and fast
induction. Its color code is yellow, and so is the app's accent.

## What you get

- **A Mac app, not a Windows window in a box.** Steam's own interface renders
  in real `NSWindow`s: traffic lights, Mission Control, full screen, the
  macOS menu bar driving Steam's menus. The friends list and chats are native
  windows. A menu-bar popover launches recent games without opening the big
  desktop window at all.
- **Real macOS notifications.** Steam's toasts become native banners with the
  sender's avatar and click-through to the chat. Presence notices withdraw
  themselves. The duplicate Windows toast is never shown.
- **It heals itself.** The `steamwebhelper` hang ("a critical Steam component
  is not responding") is a supervised, recovered condition: restart ladder,
  crash-loop hygiene, cache repair, before you see anything. Quitting the app
  takes the whole bottle down with it.
- **Every game is a Mac app.** Each game runs from its own app bundle with
  the game's name and icon, so the Dock shows the game, not "wine", and it
  can be pinned there. Because the bundle is a real games-category app,
  macOS Game Mode engages by itself when the game is full screen.
- **Games play well.** Low Power Mode and Reduce Motion are honored. Idle
  CPU is a fraction of a hand-made setup. The display stays awake while a
  game runs. A full-screen game can run in a resizable window of its own,
  the game none the wiser, with the picture scaled to whatever size you drag.
- **Settings per game, applied at the next launch.** Window treatment,
  mouse behavior and more resolve game → bottle → global, and a change
  reaches the game the next time it starts, with Steam still running: the
  built-in engine reads a per-program environment at process start instead
  of inheriting Steam's. `sevo app config <appid>` is the same surface from
  the terminal.
- **32-bit games run.** The built-in engine carries the Rosetta fixes
  CrossOver's Wine has (the 32-to-64 thunk that Rosetta otherwise loses on a
  signal, re-translation after code writes) and a 32-bit DXMT, so a 32-bit
  Direct3D 11 game reaches Metal instead of software GL.
- **RPG Maker and other NW.js games run natively.** The app recognizes a game
  built on NW.js, fetches the matching macOS runtime, and runs it as a real
  Mac process while Steam keeps counting playtime and tracking the session.
  Achievements still reach Steam through a small stand-in inside the bottle.
  The game keeps its own name and icon in the Dock.
- **A compatibility strip on every game page.** Where Steam would draw its
  Deck badge, the game page shows a Mac verdict and an anti-cheat verdict in
  Steam's own glyphs, drawn from AppleGamingWiki, AreWeAntiCheatYet and
  ProtonDB, with a Details panel that names each source and links to it.
  Kernel anti-cheat is called out before anything else, because it is the
  one failure no renderer can work around. Sources are fetched on demand and
  cached for a week, so a page answers offline after its first look.
  `sevo app compat <appid>` prints the same record.
- **Nothing else to install.** A built-in open-source engine works on a clean
  Mac. Apple's Game Porting Toolkit is fetched in-app through Apple's own
  sign-in. CrossOver is a first-class engine choice too, and the one setup
  recommends, because buying it funds the people who make Wine run on a Mac.
- **Mouse-look that feels like a mouse.** When a game takes the cursor to aim
  a camera, the engine can hand it the mouse's own movement instead of the
  Mac's accelerated pointer, so the same sweep of the hand turns the same
  distance however fast it is made. Per bottle or per game.
- **Scriptable.** The `sevo` CLI manages and heals Steam from the terminal,
  and the same verbs are an MCP server, so an AI agent can install a game or
  fix a stuck download for you.

## How it works

Two halves, and both are open.

**The interface.** The Windows Steam client runs headless in a bottle
(`-silent -cef-enable-debugging`). Steam's UI is a web app that needs only a
`SteamClient` binding. Sevoflurane serves that bundle into native
`WKWebView`s with a shim whose calls are replayed into the client's real
`SharedJSContext` over the Chrome DevTools Protocol. Protobuf traffic is
relayed around CDP through a socket the client's own context opens. Every
window Steam creates is adopted into an `NSWindow` with the right role: the
desktop, menus, friends, chat, toasts, the game overlay.

**The engine.** `sevo-wine`: upstream wine-staging 11.16 built for x86_64,
with ten patches, listed in the engine's `engine-info.json` and kept in
the `sevo-wine-build` build repository:

- **D3DMetal hosted on upstream Wine.** Apple's Direct3D 12 layer expects
  CrossOver's private glue. The patches provide it: GS base kept on the
  thread's TSD with the TEB and PEB mirrored (and the libc `localtime` slot
  it collides with left alone), the `__wine_unix_call` export, ms_abi
  wrappers for the nine syscalls D3DMetal's native threads make, and a
  `winemac.drv` presenter whose `CAMetalLayer` hook is how the driver learns a
  frame was drawn. Apple's toolkit is installed into the engine by the app;
  only Apple may distribute it.
- **msync**, CrossOver's in-process synchronization, so waits in Steam and
  in games stay off the wineserver.
- **DXMT 0.80** (Direct3D 10/11 to Metal), **DXVK 1.10.3** over MoltenVK,
  and Wine's own `wined3d`, selectable per bottle.
- **GPU identity.** The bottle reports a GeForce or Radeon of comparable
  performance to the Mac's chip, with a driver version games accept, because
  Unreal and Unity refuse to run or pick the wrong path on an unknown adapter.
- Vulkan portability enumeration (without it every CEF GPU process dies
  three times per boot), a safe-display-mode flag for Apple silicon, and a
  trimmed root-device list.

The engine ships as a versioned tarball behind a manifest, so it updates
through the app and is never frozen.

## Graphics

A Windows game needs its Direct3D calls translated to Metal. Which translator
it gets is the biggest single lever on how it runs. Settings › Graphics picks
one for the bottle:

| Renderer | What it is | Choose it when |
|---|---|---|
| **D3DMetal** | Apple's Game Porting Toolkit, Direct3D 11 and **12** | The default. The only path for DirectX 12 and for MetalFX upscaling. |
| **DXMT** | Open-source Direct3D 10/11 straight to Metal ([3Shain/dxmt](https://github.com/3Shain/dxmt)) | DirectX 11 titles. Some run better on it and some on D3DMetal; it is one switch to try. |
| **DXVK** | Direct3D 9 to 11 through Vulkan and MoltenVK | A game refuses to draw on either Metal path, or needs Direct3D 9. |
| **Automatic** | CrossOver's per-game database, then Wine's `wined3d` | You would rather trust their QA than choose. |

Toolkit releases and betas sit side by side. The newest is used unless you
pick another. DXMT is staged for both architectures, so a 32-bit game gets
Metal too.

## DirectX 12, measured

The built-in engine was run against Microsoft's DirectX-Graphics-Samples,
built on Windows with a frame-count exit, and compared with the same
binaries on an RTX 4080 SUPER (D3DMetal 4.0 beta 2). Of 35 comparable
samples, 23 draw the reference image.

| Works | Does not |
|---|---|
| The HelloWorld set (window, triangle, texture, constant buffers, bundles, frame buffering) | DirectX Raytracing, all four samples: the toolkit reports no raytracing tier |
| Execute indirect, multithreading, predication queries, reserved resources, residency, small resources, depth bounds, dynamic indexing, n-body gravity | Variable Rate Shading: no tier reported, the sample gives up |
| Mesh shaders: meshlet render, cull, instancing | Mesh shaders: dynamic LOD renders the mesh as shards (the amplification path) |
| Full screen, linked-GPU samples on one adapter | Cross-GPU copy (one adapter is exposed) |
| | Pipeline state cache, generic programs, 11-on-12: abort at the first Direct3D 12 call |
| | HDR and SM6 wave intrinsics: stop on their own error dialog |

Capabilities as the toolkit reports them next to the RTX card: feature
level 12_2, resource binding tier 3, heap tier 2, enhanced barriers, wave
operations and mesh shaders match. Shader Model is 6.6 against 6.8, root
signature 1.1 against 1.2, tiled resources tier 2 against 4; conservative
rasterization, sampler feedback, double-precision shaders and raytracing are
absent. Games that need those will say so; the rest of Direct3D 12 is
there. The Agility SDK redirect games ship is never honored; the engine's
own `d3d12.dll` answers every time.

## Known limits

- **Games with kernel anti-cheat stay on Windows.** EasyAntiCheat, BattlEye
  and similar need a Windows kernel driver. This is Wine's boundary and it is
  the same for every tool of this kind.
- **Everything under the app runs as x86_64 under Rosetta.** macOS 27 is the
  last release that carries Rosetta in full. The app itself is native and
  emulates nothing. CodeWeavers' answer for the layer below is native ARM64
  Wine with FEX, aimed at CrossOver 27; per-title speed there is unmeasured.
- **Game compatibility belongs to CodeWeavers and Apple.** This app claims
  the experience: the client always opens, the windows are Mac windows, the
  failures recover. Whether a given game runs is the engine's story. Check
  CrossOver's database and AppleGamingWiki.
- **DirectX 12 is measured on samples, and played on one game.** The table
  above is the samples; Subnautica 2 (Unreal Engine 5) runs through Steam
  on the built-in engine. Numbers nobody measured are not quoted here.
- **`.NET 4.8` is left out of the dependency installer** on purpose:
  winetricks marks it broken on several Wine versions.

## Running (dev)

Requirements: macOS 26+, Apple silicon, Xcode 26+. CrossOver is optional.

1. Build and launch the `Sevoflurane` scheme. The first run walks through
   setup: it creates the bottle, installs Steam, and signs in.
2. After that the app starts the bottled client with CDP on `:8765`, boots
   Steam's UI through the in-process bridge, and supervises from there.
3. Diagnostics: `sevo doctor`, the event log at
   `~/Library/Logs/Sevoflurane.log`, Wine's own log at
   `~/Library/Logs/Sevoflurane-wine.log`.

## `sevo`, the CLI

`swift build` produces `.build/debug/sevo` (`sevo install-cli` symlinks it
into `/usr/local/bin`). One management surface for terminals and agents:

```
sevo doctor [--json]        environment diagnosis, one line per check
sevo status [--json]        engine · bottle · client · bridge · app
sevo client start|stop|restart|update|pin|unpin
sevo recover [--deep]       the wedge playbook; --deep adds cache purge and repair
sevo app list|info|launch|terminate|install|verify|uninstall
sevo downloads status|pause|resume|throttle KBPS
sevo run PROGRAM [ARGS]     one Windows program in the bottle, under the game's engine
sevo eval 'JS' · sevo cdp 'JS' [TARGET] · sevo logs [--tail N] [-f] [--wine]
```

`--json` everywhere. Exit codes: 0 ok · 1 failed · 3 not provisioned · 4
client unreachable. When the app is running, mutating verbs go through its
supervisor, so the restart ladder has one owner.

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

## Layout

- `Sevoflurane/` — the app (Swift 6). `Web/` hosts Steam's UI and windows,
  `Bridge/` is the page↔client bridge, `Setup/` the first-run assistant,
  `App/` supervision, logging and the menu bar, `Support/` bottle paths,
  engines and subprocesses.
- `Sevo/` + `Package.swift` — the `sevo` CLI and MCP server, sharing the
  app's lifecycle and CDP sources.
- `Tools/` — the dock shim, packaging, test scripts.
- `Site/` — the landing page.

Engine sources, patches and harnesses live in the `sevo-wine-build`
repository, which the engine tarball is packed from.

## Contributing

See `CONTRIBUTING.md`. Start with the fidelity rules; most non-obvious bugs
here are a violation of one of them.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
