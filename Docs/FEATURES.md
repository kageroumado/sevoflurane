# Sevoflurane features

Everything Sevoflurane does, grouped by where you meet it. The [README](../README.md)
introduces the app; this list is the full inventory, including the parts that
only show up when something goes wrong. Features marked **(Dormison)** need
the Dormison engine; CrossOver runs everything else.

## Setup

- **A first-run assistant** that takes a Mac from nothing to a signed-in Steam:
  a welcome page, the engine, the bottle, the install, DirectX 12, startup
  options, community sharing and a done page.
- **Engine choice.** Dormison, the free engine built for Sevoflurane (bundled
  with the app or downloaded), or any installed copy of CrossOver or CrossOver
  Preview, with each copy's trial or license state.
- **Bottle choice.** Adopts a Steam already installed on the Mac (a single
  candidate is picked for you; several are offered) or makes a new named
  bottle. "Download everything" adds the optional fonts and legacy runtimes
  (about 320 MB).
- **Install progress** in six named stages (Rosetta, engine, Steam's folder,
  installer, Steam, fonts and runtimes), with a live percentage. Setup
  installs Rosetta when it is missing.
- **DirectX 12 step.** Gets Apple's Game Porting Toolkit three ways: sign in
  with Apple inside the app, download it in your own browser while
  Sevoflurane watches the Downloads folder, or point at a file you already
  have. Skipped for CrossOver, which brings its own D3DMetal.
- **Startup and automation.** Open at login, and install the `sevo` command.
- **Community sharing consent**, asked once, before the last page.
- **Setup can be set aside.** Closing the window keeps it running in the menu
  bar; the Dock tile, the popover or reopening the app brings the same window
  back. Steam's own windows stay hidden until you finish.
- `sevo setup` does the same without a window.

## Steam in Mac windows

- **Steam's library, store, friends and chats in native macOS windows**,
  drawn from Steam's own interface, with real traffic lights in place of
  Steam's Windows title bar.
- **Steam's menus in the macOS menu bar**: Steam, View, Friends, Games and
  Help, kept in step with the client.
- **Copy and paste** in chats, search fields and notes through a native Edit
  menu.
- **Store, community and profile pages signed in**: they open as native web
  views that share the client's session.
- **Friends and chats as their own windows.** Opening Friends with unread
  messages goes to the oldest waiting conversation, the way Steam's tray icon
  does.
- **Steam's notifications as macOS notifications**, with Steam's own
  per-conversation sound choices. Permission is asked for only once Steam has
  something to show.
- **The in-game overlay (Shift+Tab)** as a panel over the game that never
  takes focus from it.
- **Big Picture, the on-screen keyboard and the controller configurator**
  each get a window of their own.
- **Launch options answered natively.** When Steam would ask which way to
  start a game, Sevoflurane asks with a macOS alert, using Steam's own
  descriptions of each option.
- **Steam links.** `steam://` links on the web (install buttons, invites) open
  in Sevoflurane; Settings › General claims them with one click.
- **Low Power Mode and Reduce Motion** turn on Steam's matching settings,
  which stop its animated artwork, and your own values come back afterwards.
- **A Mac compatibility strip on game pages**: Mac and anti-cheat reports from
  AppleGamingWiki, AreWeAntiCheatYet and ProtonDB in the slot Steam's Deck
  strip leaves empty, with a Details panel that links each source.

## The menu bar

- **Recent games** with their capsule art, a play button, and live launch
  status from Steam's own game events.
- **Your whole library**: scrolling past the recent five brings up every
  installed game, indexed by letter.
- **Per-game menu**: Run with… (a renderer for this launch), Always run with…
  (a renderer for every launch), Game Settings…, and **Keep in Dock**. A game
  row also drags out onto the Dock.
- **Quick Launch programs** beside your games, with their own icons and a note
  when a program's file has moved or been deleted. Their menu adds Show in
  Finder and Remove. **Add Windows Game…** opens a file picker.
- **A health card** that names the client's state and offers the fix:
  starting, waiting for sign-in, degraded, restarting, gave up (Restart Now,
  Recovery…) or auto-restart paused.
- **Background-helper approval card** with Open Login Items and Retry, when
  macOS has not approved the helper yet.
- **A host-pressure notice** naming the program taking the most processor or
  memory, shown only while the Mac is under more than ordinary load (also
  temperature and Low Power Mode).
- **A note when Steam holds a game at "Synchronizing"** longer than a cloud
  sync takes.
- **"Bottle incomplete"**, a quiet note when required Windows components are
  missing, which opens the place to install them.
- **The Steam row**: Open Steam (⌘O), Friends (⌘F, with an unread count) and a
  status chip whose tooltip carries the latest log line.
- **The actions menu (⋯)**: Reload Steam UI, Restart Steam Client, Restart
  Windows, Force-Quit Steam, Force-Quit Everything, Open Event Log, Debug
  Mode, Auto Update and the version.
- **A renderer switch** in the footer.
- **Quit confirmation** that says quitting also closes Steam and any game.

## Playing games

- **Each game is its own app to macOS (Dormison)**: its own Dock tile, name
  and icon, and Game Mode while it is frontmost and full screen. A helper
  program a game starts never takes the game's tile.
- **Keep in Dock**: the game's tile stays in the Dock beside your apps, and a
  click on it starts the game through Sevoflurane.
- **Resizable windows (Dormison)**: full-screen or fixed-size games run in a
  window you can resize while the game keeps its own resolution.
- **Upscaling (Dormison)** with Lanczos, MetalFX, Anime4K or CuNNy, plus a
  final filter. It covers games drawn through Metal (D3DMetal), OpenGL (Wine's
  built-in renderer, which most Direct3D 9 visual novels use) and plain GDI
  windows.
- **A View menu in every game (Dormison)**: switch the upscaler and final
  filter live, Show Frame Rate (⌥⌘F), Show Frame Time Graph (⌥⌘G: rate, 1%
  low and a per-frame timeline) and Show Picture Details (⌥⌘I: source and
  target size, upscaler, filter).
- **DLSS through MetalFX** on D3DMetal: a game's own DLSS setting works as it
  does on an NVIDIA card.
- **Five renderers**: D3DMetal (Direct3D 11 and 12), DXMT (10 and 11 over
  Metal), DXVK (9 to 11 over Vulkan), Wine's built-in renderer, and Automatic
  (CrossOver's per-game choices). Toolkit versions, including betas, and DXMT
  and DXVK versions install side by side.
- **Mouse-look and cursor confinement (Dormison)** for games that need raw
  mouse movement or clip the cursor to their window.
- **The display stays awake while you play.** A Windows game never counts as
  activity to macOS; Sevoflurane holds the display awake while a game window
  is up and lets it sleep once the game is gone.
- **"Game has stopped answering"**: a game whose window no longer takes its
  close button gets Keep Waiting or End Game.
- **NW.js games natively**: RPG Maker MV and MZ games and other NW.js titles
  run on a macOS NW.js runtime, while Steam still counts playtime and awards
  achievements.
- **Discord shows what you play.** Sevoflurane publishes "Playing <game>"
  under the game's own Discord entry, and games with their own Discord support
  publish their own status through a relay in the bottle (Dormison). Two
  switches in Settings › General.

## Windows programs outside Steam

- **Open any `.exe` with Sevoflurane** from Finder, or pick Add Windows Game…
  in the menu bar. An adoption panel shows the program's own icon, name and
  version and whether it looks like a game or an installer (you can
  overrule it), then plays it once or adds it to Quick Launch.
- **Installers run to completion**, and Sevoflurane then lists the programs
  they added so you keep the ones worth keeping. Settings › Storage shows what
  each installer wrote and moves it to the Trash when you remove the program.
- **Quick Launch programs play like Steam games**: the same per-game settings,
  Dock tile, run records and reports.
- **Finder thumbnails for Windows programs**: every `.exe` shows its own icon
  in Finder's icon, list and gallery views and in Quick Look, drawn from the
  file itself without running anything. Available once Sevoflurane has run
  once.
- **A note when a program needs a Windows kernel driver**, which Wine cannot
  load, instead of a program that silently shows nothing.
- **HoYoverse games** (Genshin Impact is the one tested) run in a companion
  Windows beside the Steam bottle, under a `steam.exe` parent, which lets them
  skip their kernel driver. Settings › Games › Genshin Impact starts a
  frame-rate unlocker of your choosing beside the game.

## Settings

A searchable window: searching lists matching settings, not only panes, and
flashes the row you pick. Each setting has a title, one line, and an (i) that
explains it and when to change it.

- **General**: open at login, auto-restart Steam, Steam's own settings, Steam
  links, the command-line tool, AI assistants, the Mac compatibility strip,
  community sharing, Discord, and uninstall.
- **Graphics**: the default renderer (with a notice when the running client
  started on another), the GPU games are told they run on, DXMT and DXVK
  versions, and shader packages for the upscaler.
- **Engine**: engines and bottles, the release channel, enhanced
  synchronization (msync), defaults for every game (window, upscaler, filter,
  mouse, performance), game dependencies, DLL overrides, Wine configuration,
  library-load logging, and repair.
- **Games**: one game's picture, mouse, performance and DLL-override settings,
  each inheriting from Engine until you change it. **Known fixes** mark the
  setting a particular game needs, one click to apply.
- **Storage**: see below.
- **Recovery**: see below.
- **Diagnostics**: how much a run records, a guide to a useful report, the
  collected reports, and the disk space diagnostics may use.
- **About**: version, links, Acknowledgements (every third-party component and
  data source with its license) and the app's license.

### Game dependencies

Visual C++ runtimes, the Direct3D shader compiler, the DirectX June 2010
runtime, core fonts and Chinese, Japanese and Korean fonts, each installable
on its own with its state shown. A new bottle gets all of them by default.

### DLL overrides

Wine's own load orders (native, built-in, either first, disabled) for the
whole bottle or for one game. `sevo app repair-dll` installs the package that
carries a missing DLL and pins the fix to that game.

## Storage

- **A whole-disk bar**: Sevoflurane's largest categories, the rest of its
  data, and everything else on the volume.
- **Every category with its size**, and a Trash button for what can be made
  again (client caches, engines, renderer versions, shader packages).
- **Every game and program with its size**, matching what Steam reports.
  Games uninstall through Steam, which asks first.
- **Game libraries**, with a warning for a drive Wine cannot rely on.
- **Share games between bottles.** A game installed in another bottle, on any
  engine including CrossOver, links into this one without a second download:
  one copy on disk, and each bottle keeps its own saves. A link applies at the
  next Steam restart and can be undone before that.
- `sevo storage` prints the same inventory.

## Keeping Steam healthy

- **A background helper owns the Windows side.** It watches the client for
  hangs and crashes, restarts it, clears its web cache and repairs it; a crash
  loop that survives one clean-up pass stops retrying and reports.
- **Quitting and crashing are different things.** Quitting Sevoflurane quits
  Steam and everything in the bottle. If Sevoflurane crashes or is force-quit
  while you play, the game keeps running and reopening the app reattaches.
- **The sign-in screen is a state, never a fault.**
- **Patience under load.** While the Mac is busy (other apps' processor time,
  memory pressure, temperature, Low Power Mode) the helper waits two or three
  times as long before calling a slow client hung, and logs why.
- **Leftover Wine processes** whose server has died are ended automatically;
  `sevo orphans` lists them.
- **Settings › Recovery**: Restart Steam, Force-quit Steam, Cancel stuck menus
  (the macOS 27 menu freeze), repair the background helper, repair the bottle,
  reinstall the Direct3D shader compiler, Restart Windows, clear the shader
  cache, rebuild the Steam environment (keeps games and saves), and Wine
  configuration.
- **Common problems**, a built-in guide from symptom to fix: missing-runtime
  DLL errors, a mod or loader being ignored, a black screen from the shader
  compiler, boxes in place of text, the wrong renderer for a game, a black
  intro video, the menu freeze, and a helper that will not start. Each names
  the error text to look for and links the fix.

## Community game database

- **Share run statistics** (Settings › General › Community, asked once): each
  run you finish is sent to
  [kagerou.glass/sevoflurane/games](https://kagerou.glass/sevoflurane/games)
  with the game, engine, renderer, settings, macOS, chip, how long it ran, its
  frame rate over gameplay, and how it ended. Nothing that names you or your
  Mac goes with it. A preview shows the exact payload.
- **Signed by this Mac.** Each install signs its runs with a key made in the
  Secure Enclave, attested with App Attest where the Mac supports it.
  **Delete What I Shared…** (or `sevo stats delete`) takes it all back and
  starts a new anonymous identity.
- **"How did it go?"**: a verdict for a run (Plays, Plays with fixes,
  Launches, Fails) and an optional note, from the Reports window or
  `sevo report`.
- **Game pages** show how a game runs per engine and chip, and the reports
  left about it with the configuration each ran on. Games Steam does not sell
  get pages once adopted into the catalog.

## Diagnostics and reporting

- **Three recording levels.** Always: a run record, a frame-time trace, the
  event log, Wine's errors and a report after a crash. Diagnostics adds Wine's
  exceptions, renderer logs and a report after every run. Everything adds
  every library load, graphics logs, full minidumps and host samples, and
  turns itself off after one game.
- **Debug Mode**: one switch for everything a report needs, for one session.
- **The Reports window**: every run (game, what it ran on, how long, how it
  ended), its record, frame rate and collected errors, a plain-language
  diagnosis when the failure is a known one, and buttons to save the ZIP or
  open a pre-filled GitHub issue.
- **Crash reports offered once per crash.** After a crash or a hang the
  watchdog ended, a panel offers to send the redacted report to the
  developers; "Never ask again" turns it off.
- **Save Diagnostics…**: a ZIP of logs, a `sevo doctor` report, engine
  details, Steam's own logs and recent crash reports, with your account name,
  paths, Mac name and Steam ids taken out.
- **The Process Monitor**: every process Sevoflurane owns, what each is doing,
  and a flag on a game that has pinned one core for a minute.
- **Size caps** on every log and report, oldest removed first.
- **Frame-time comparison.** `sevo perf compare` groups runs by configuration
  and says whether average frame rate and 1% low actually moved, with a 95%
  interval; `sevo perf report` draws it as a page.
- `sevo holds` names what keeps the display awake, including the Windows
  program behind a Wine-owned hold.

## Updates

- **The app updates itself** from GitHub Releases: checked daily and installed
  once the Mac is idle and no game is running, or at once from the footer's
  Update chip. Auto Update can be turned off.
- **Engine and renderer updates** show as a dot on the Settings button. Dormison
  releases are signed and checked before they install; a stable and a beta
  channel are available.

## Command line and AI assistants

`sevo` ships in `Sevoflurane.app/Contents/Helpers`, and Settings › General
installs it on your `PATH`. Every command takes `--help`.

```text
sevo doctor | status | wait [--gone]
sevo setup [--engine E]
sevo engine list | install [--file F] | d3dmetal | use | channel [stable|beta] | check-manifest
sevo update check | use | install | remove        DXMT and DXVK versions
sevo shaders list | install | remove
sevo bottle list | config [key [value]] | deps [install ID]
sevo storage [--games]
sevo client start | stop | restart | force-quit | update | clear-shader-cache | pin | unpin | logs
sevo recover [--deep]
sevo daemon repair
sevo app list | info | compat | config | repair-dll | detect | launch | terminate | install | uninstall | verify
sevo program add | list | remove | launch | run
sevo nwjs list | add
sevo downloads status | pause | resume | throttle
sevo runs | report RUN --verdict V [--note N]
sevo perf list | report | compare | label | mark
sevo stats status | preview | reports | delete
sevo diag save | on | off | status
sevo debug on | off | status
sevo logs [--tail N] [-f] [--wine]
sevo holds | orphans
sevo run PROGRAM [ARGS]
sevo eval 'JS' | cdp 'JS' [TARGET]
sevo benchmark
sevo mcp | install-cli | version
```

- **An MCP server** (`sevo mcp`, stdio) with 27 tools: diagnosis, status,
  engines, client start, stop, restart and recovery, the library, app info,
  launch, install, uninstall and verify, Quick Launch programs, downloads,
  frame-time comparison, recent runs, diagnostic levels and saving a report,
  and logs. `eval_js` joins them only with `SEVO_MCP_ALLOW_EVAL=1`. Resources:
  `sevo://status`, `sevo://doctor`, `sevo://log`, `sevo://library`. The server
  teaches the calling model how to make a useful diagnostic run.
- **One-click assistant setup.** Settings › General registers `sevo` with each
  assistant it finds: Claude Code (with a skill that teaches the diagnostic
  run), Claude Desktop, Codex and Hermes. Each row shows where it writes, and
  a command to paste covers any other assistant.

## Engines

- **Dormison**, the free Wine engine built with Sevoflurane
  ([github.com/kageroumado/dormison](https://github.com/kageroumado/dormison)):
  Wine 11.16 with wine-staging, plus D3DMetal support, msync, 32-bit games
  under Rosetta, Steam start-up fixes, the presenter (upscaling, resizable
  windows, the View menu), Dock integration, the Discord relay, Media
  Foundation video through GStreamer, Japanese fonts, and a native arm64
  wineserver.
- **CrossOver and CrossOver Preview** run as engines too, with CrossOver's own
  D3DMetal and per-game choices.
- **Crash fixes for known D3DMetal builds.** A toolkit build known to crash a
  game gets a byte-exact correction on your copy, pinned to that one build;
  the untouched file stays beside it, and installing the toolkit again brings
  Apple's back.
- **Switching engines** is a setting (`sevo engine use`); a client restart
  boots the engine you chose.

## For contributors

- **A Debug build is a second installation** beside the installed app, with its
  own name ("Sevoflurane Debug"), folders, settings, background helper, ports
  and `sevo-debug` command, and a hammer on its menu-bar icon.
  [CONTRIBUTING.md](../CONTRIBUTING.md) has the details.
- **The UI gallery** (`Tools/gallery-export.sh`) renders every Settings pane,
  popover state, Reports window and setup step from fixtures to PNG, touching
  nothing on the Mac.
- **The `sevo` debug verbs** (`eval`, `cdp`, `run`, `benchmark`) and the app's
  loopback endpoints drive the running client for tests and scripts.

## Known limits

- Games and online modes that need Windows kernel anti-cheat do not run.
- The Windows side runs under Rosetta and pays its translation cost.
- DirectX 12 needs Apple's Game Porting Toolkit, which only Apple may
  distribute; 32-bit DirectX 12 games do not run.
- The upscaler joins a game when it starts. Switching upscalers applies at
  once; turning it on or off applies at the next launch.
- OpenGL drawables that are multisampled, stereo, floating-point or 10-bit are
  shown without the upscaler. DXMT and DXVK through the presenter are untested.
- Media Foundation video decodes in software.
- Unity games on Mono that crash within seconds of launch are an open engine
  bug.
- Steam's in-game overlay is a window beside the game, not drawn into the
  game's picture.

## Appendix: Dormison switches

The engine reads these per bottle (`HKCU\Software\Wine\Mac Driver`) or from
the environment and the `.sevo` env files the app writes. Settings and
`sevo bottle config` / `sevo app config` set them for you; they are listed for
anyone driving the engine directly.

### Registry keys (`HKCU\Software\Wine\Mac Driver`)

| Key | Default | What it does |
|---|---|---|
| `StatusItems` | shown | `N` leaves a program's tray icon to explorer's own window instead of the Mac menu bar |
| `ResizableWindows` | off | lets a game's window resize while it keeps its own resolution |
| `Presenter` | off | turns on the presenter with plain resampling |
| `Upscaler` | `off` | Lanczos, MetalFX Spatial or a shader package (Anime4K, CuNNy, …); anything but `off` turns the presenter on |
| `FinalFilter` | `lanczos` | the resampling pass after the upscaler |
| `FrameRate` | off | the frame-rate capsule |
| `FrameRateGraph` | off | the frame-time card (turns `FrameRate` on) |
| `OpenGLPresenter` | on | `N` keeps every OpenGL drawable off the presenter |
| `LinearMouse` | off | raw mouse-look movement |
| `CursorConfine` | off | window-server cursor confinement for a game's clip |
| `PresentationLog`, `PresenterLog`, `PresenterDebug` | off | presentation and presenter logging |

### Environment variables

| Variable | What it does |
|---|---|
| `SEVO_RESIZABLE_WINDOWS`, `SEVO_PRESENTER`, `SEVO_UPSCALER`, `SEVO_FINAL_FILTER`, `SEVO_FPS`, `SEVO_FPS_GRAPH`, `SEVO_GL_PRESENTER`, `SEVO_LINEAR_MOUSE`, `SEVO_CURSOR_CONFINE` | bottle-wide defaults for the registry keys above |
| `SEVO_PRESENTATION_LOG`, `SEVO_PRESENTER_LOG`, `SEVO_PRESENTER_DEBUG`, `SEVO_GFX_LOG` | presentation, presenter and D3DMetal present-hook logging |
| `SEVO_SHADER_DIR` | where the presenter loads shader packages from |
| `SEVO_GPU_VENDOR_ID`, `_DEVICE_ID`, `_NAME`, `_MEMORY_MB`, `_DRIVER_VERSION`, `_DRIVER_PROVIDER`, `_DRIVER_DATE` | the GPU identity, memory and driver a Windows program sees (NVIDIA metadata when the vendor is unknown) |
| `SEVO_FORCE_UMA` | `1` reports the GPU's real unified-memory answer and the Mac's real memory |
| `SEVO_LARGE_ADDRESS_AWARE` | `1` gives a 32-bit program the full 4 GB |
| `SEVO_OBJECT_SPIN`, `SEVO_ACK_SPIN`, `SEVO_WAIT_SPIN`, `SEVO_WAIT_SPIN_ADAPT`, `SEVO_YIELD`, `SEVO_ALERT_ALWAYS_WAKE` | optional spinning before a thread waits (off by default) |
| `SEVO_SYNC_STATS` | a path to write per-process wait counters to |
| `SEVO_COREAUDIO_DEVICE_BUFFER` | `1` writes buffer size and volume to the whole device, for comparison |
| `SEVO_ENV_FILES` | `0` turns off the `.sevo` env files and the bundle loader together |
| `SEVO_OWNER_PID`, `SEVO_SUPPRESS_WINDOWS`, `SEVO_LOADER`, `SEVO_LOADER_TREE` | the Dock shim: the process whose exit ends the bottle, hiding Steam's own windows, and the loader |
| `SEVO_RUNNER`, `SEVO_NWJS`, `SEVO_NWJS_DIR` | the Dock shim's native NW.js runner |
| `SEVO_STEAM_STUB`, `SEVO_STEAM_APPID`, `SEVO_STEAM_STUB_DIR`, `SEVO_STEAM_STUB_PORT`, `SEVO_STEAM_STUB_IDLE`, `SEVO_STEAM_API_DIR` | the Steamworks stub that gives native NW.js games achievements |
| `SEVO_CLI` | the `sevo` the View menu calls |
