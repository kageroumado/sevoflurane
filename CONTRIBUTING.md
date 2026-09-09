# Contributing to Sevoflurane

Thanks for looking under the hood. A few things make this codebase easier to
work on than it first appears — and a few rules keep it that way.

## Orientation

- `Sevoflurane/` — the app. `Web/` hosts Steam's UI and windows; `Bridge/`
  is the in-process page↔client bridge; `App/` is supervision, logging, and
  the menu bar.
- `Sevo/` — the `sevo` CLI and MCP server (`swift build`). It compiles the
  app's own provisioning, CDP and lifecycle sources, so the two cannot drift.

## Building

Xcode 26+, macOS 26+, Apple Silicon. Open `Sevoflurane.xcodeproj`, pick your
own team under Signing & Capabilities, and build the `Sevoflurane` scheme. To
run against Steam you need a bottle with Steam installed: the app's first-run
assistant creates one on the engine it installs, and `sevo setup` does the
same from the terminal.

## Simulating a Steam event

Most of what this app reacts to arrives from Steam and needs a friend on the
other end. Both halves of that can be driven instead.

**Without a client.** The decisions are values, so the tests need no bottle,
no window, and no sleep: `UnaskedChatPolicy` takes its clock as an argument
and answers whether a chat window Steam is showing was asked for;
`SteamNotification` decodes the payload the context page posts, and
`SteamNotifications.Presentation` turns it into words and a route. Drive
those directly — `SevofluraneTests/IncomingChatTests.swift` is the worked
example. Running the tests launches the app, because they link against it,
so the app returns immediately when `XCTestConfigurationFilePath` is in its
environment: a test run starts no bridge, no supervisor, and no client.

**Against a running client**, `Tools/chat-scenarios.sh` synthesizes an
arriving message through Steam's own objects — no second account. It calls
`UIStore.ShowAndOrActivateChat(context, chat, false)`, which is exactly what
Steam's `IncomingMessage` handler calls, and pushes a notification payload
into the context page's `__steamNotification` handler, which is where the
`NotificationStore` subscription delivers. It asserts through
`:8764/windows` and `:8764/log/tail`, prints PASS/FAIL per scenario, and
restarts nothing.

The three endpoints behind it are the general tools: `GET :8764/windows`
lists every window the app owns with its role and whether it is visible,
`GET :8764/log/tail?n=N` is the log without a file path, and
`POST :8764/chat/open?accountid=N` makes the call a clicked notification
makes. `sevo eval` runs JavaScript in the app's context page; `sevo cdp`
runs it in the bottled client's own `SharedJSContext`, which is a second
copy of the same UI and reacts to the same events.

## Fidelity rules

The non-obvious bugs in this project are almost always a violation of one of
these. All five are load-bearing.

1. **Mirror the real client's shape.** The shim must expose the same
   namespaces and methods the desktop client has — a catch-all Proxy makes
   the UI call methods that do not exist.
2. **Binary as base64 envelopes with the view type, recursing into plain
   objects.** A `Uint8Array` nested in an object that crosses as JSON hangs
   `ParentalStore.Init()` and the entire pre-login stage.
3. **Never stringify a rejection object.** Steam rejects with objects the UI
   branches on (`{result: 2, message: 'Not found'}`).
4. **Route callbacks to the page that registered them.** Broadcasting them
   let two pages run each other's handlers, which silently left stores
   unpopulated.
5. **Send `"popup-created"` to every popup.** Steam's UI defers all
   rendering into a popup until that message arrives, and the per-window
   `SteamClient` must be injected as CEF would.

## Rules of the road

1. **The supervisor owns the client lifecycle, and it lives in the daemon.**
   Nothing else may launch or kill bottle processes; new recovery behavior
   goes through its ladder, in `SevofluraneDaemon`. The app never supervises,
   not even as a fallback — see *Two processes* below.
2. **Steam's watchdog dialog is a symptom, never a control surface** — the
   app detects and recovers; it does not click Wine dialogs.
3. **US English** in code, comments, and strings. DocC comments on public
   interfaces. Split long functions instead of adding section comments.
4. **Logs are the product too.** User-visible failures must land in the
   event log (`~/Library/Logs/Sevoflurane.log`) with enough context to act
   on.
5. **A renderer's two halves are one release.** D3DMetal is a macOS library
   (`wine/lib/external/libd3dshared.dylib` and the framework) plus that
   toolkit's Windows DLLs, and the `.so` stubs in the Wine tree are symlinks
   into the first — so the version sitting in the tree is the one a game
   runs, whatever a preference says. Staging asserts both halves on every
   boot. Never pair one release's DLLs with another's library: a PE DLL
   carries a function index into the unix-side library and the releases do
   not number those alike, so the failure is a call into the wrong function
   with nothing in any log.
6. **No `Section` inside a `List` in Settings.** Panes are `Form` with
   `.formStyle(.grouped)`; a `List` here is only ever a flat sidebar of one
   kind of row. A section header row beside content rows gives AppKit's
   table a header row view and a content row view to constrain against each
   other across a diff, and rows recycled between the two kinds are pinned
   to anchors in a hierarchy they have already left — an AutoLayout
   exception raised inside the display cycle, which AppKit turns into a
   crash. A SwiftLint custom rule (`settings_list_section`) fails the build
   on it.

## Two processes

`SevofluraneDaemon` is a `KeepAlive` LaunchAgent that ships inside the app
bundle (`Contents/Library/LaunchAgents/`), is signed with it, and is
registered by the app with `SMAppService.agent(plistName:)` on first launch.
It owns every bottle process: the restart ladder, the probe cycle, the popup
sweep, crash-loop hygiene, and the control port `:8764` that `sevo` speaks to.
Sevoflurane.app owns the page — the WKWebViews, Steam's popups, the bridge —
and attaches to the daemon as a client.

Two truths the split keeps at once:

- **Quitting takes the bottle down.** The app's quit path asks the daemon
  once (`POST /quit`) and waits for it.
- **A crash does not.** A `kill -9`, a force-quit or an uncaught exception
  sends nothing, so the game keeps running and a relaunched app reattaches.

Every spawn carries `SEVO_OWNER_PID` — the daemon's pid (`BottleOwner`). The
engine's dock shim opens a `kqueue` `NOTE_EXIT` on it and runs `wineserver -k`
if the *daemon* dies, so a bottle can never outlive its owner.

There is no in-process supervisor. A daemon that cannot be registered or
reached is a terminal state: the menu bar says so and offers Login Items and
a Retry, and `sevo` says so and offers to start it. Do not add a fallback —
two owners of one bottle is the bug this design exists to make unrepresentable.

### The link

Two loopback HTTP listeners push to each other; nothing polls and nothing
correlates, because the daemon only ever sends commands and the app only ever
sends facts (`Support/SupervisorLink.swift`).

| direction | endpoint | payload |
|---|---|---|
| app → daemon | `POST :8764/app/facts` | `PageFacts`: the app's pid and version, whether the page holds Steam's login window, whether the bridge's socket to the client is open |
| app → daemon | `POST :8764/app/detach` | the app is quitting |
| app → daemon | `POST :8764/supervisor/wake` | the app saw something the cycle should not wait a tick for |
| app → daemon | `POST :8764/game/launch` | a game the menu picked, with its renderer pin |
| app → daemon | `POST :8764/bottle/run`, `/bottle/launch` | one Windows program, so the daemon stays the only parent |
| daemon → app | `POST :8766/command?verb=` | `PageCommand`: `connectToClient`, `reload`, `rebuild`, `dismissWindows`, `dismissWindowsForQuit`, `clientStopBegan`, `clientStopEnded`, `showLibrary` |
| daemon → app | `POST :8766/command/launch?appid=` | run the game now, the restart having been decided |
| daemon → app | `POST :8766/state` | `SupervisorSnapshot`: the health verdict the menu bar draws |
| daemon → app | `POST :8766/log` | one log line, for the in-memory trail (both processes append to the same file) |

The app's own verbs (`/windows`, `/steam/show`, `/menu/cancel`, the
benchmarks) stay on `:8766` and are proxied through `:8764`, so `sevo` asks
one port for everything and gets a 409 when no app is running.

Anything the daemon needs about the *client* it asks the client: CDP on
`:8765` and the page's `/__eval` on `:8762` are reachable from either process,
so services-readiness and page health are not facts the app has to relay.

### Which target compiles what

Three build products, one source tree. `SevofluraneTests/DaemonMembershipTests`
asserts the daemon compiles everything `Package.swift` gives `sevo`, and
nothing that imports SwiftUI, WebKit or Propofol. A new file under
`Sevoflurane/` joins the daemon target unless the project's exception list
names it, so a new view means one line added there — and the test fails until
it is.

## Watching a game or the client from outside

Two logs, and they answer different questions. The event log is the app
narrating itself; the wine log is Wine and everything it started, which is
where a game's death actually shows up.

```bash
sevo logs --tail 50            # ~/Library/Logs/Sevoflurane.log — the app
sevo logs --wine               # ~/Library/Logs/Sevoflurane-wine.log — Wine
sevo bottle config wine-debug -- "+seh,err+all"   # channels; `off` for quiet
sevo run <program> [args] [--wait]                # one program in the bottle
```

`wine-debug` takes Wine's own channel syntax and applies at the next client
start; the leading `-` needs the `--` first, or the argument parser reads it
as a flag. **`+seh` is the one worth knowing**: Windows programs, Steam very
much included, emit their diagnostics as `OutputDebugString`, which arrives
as a `DBG_PRINTEXCEPTION_C` record on that channel. A crash then has the
program's own last line sitting directly above it, which is usually the whole
diagnosis. It is verbose — turn it off again.

`sevo run` is the launcher for anything that is not the client: a game's own
exe, a harness, `winecfg`. It refuses `steam.exe`, whose lifecycle belongs to
the supervisor. A game launched this way, outside Steam, will normally exit
at once through `SteamAPI_RestartAppIfNecessary`; putting the appid in a
`steam_appid.txt` beside the exe, with the client already running, lets it
start against the live client.

## Bottles and engines

A game's own setup state — EULA, gamma step, settings, saves — lives under
the prefix, `drive_c/users/<user>/AppData/Local/<Game>/Saved/`. The built-in
engine uses `Sevoflurane/Bottles/Steam` with the macOS account's short name
as the Windows user; CrossOver uses `CrossOver/Bottles/Steam` with user
`crossover`. Switching engines hands
the game a prefix it has never seen, so it runs first-time setup again. Game
files are shared (`steamapps/common` is symlinked between bottles); config
and saves are not. Steam Cloud carries saves across.

Stop a wedged game with `sevo app terminate`. SIGKILLing it breaks msync's
Mach service for the prefix until the client restarts.

## Measuring boots, stops, and windows

- **Audit lines** in `~/Library/Logs/Sevoflurane.log`: `boot audit: Ns from
  launch to healthy` at every healthy transition; `stop audit: graceful exit
  in Ns` / `forced down in Ns` / `client-only …` at every stop. Phases: grep
  `launching the bottle client`, `client is back`, `client services ready`,
  `healthy:`.
- **Window chronicle** `~/Library/Logs/Sevoflurane-windows.log`: every window
  a bottle process tried to show, with time, exe, class, title, size, and
  whether the shim suppressed it (`armed` / `suppressed` / `passed <exe>`).
- **The shim** (`build-macos/dock-shim/sevo_dock_shim.c` in the engine
  repository, [kageroumado/dormison](https://github.com/kageroumado/dormison);
  built into the engine directory as `libsevodockshim.dylib`, wired by
  `Engine.environment` with `SEVO_SUPPRESS_WINDOWS=1`): no Dock promotion
  and no windows for Steam's infrastructure processes. It ships inside the
  engine tarball; the build command is in that repository's
  `build-macos/README.md`.
- **Steam's own logs are the phase map** for anything inside the client, in
  the bottle's `Program Files (x86)/Steam/logs/`: `bootstrap_log.txt`
  (updater), `webhelper.txt` (CEF spawns), `steamui_login.txt` (login state
  machine), `connection_log.txt` (connectivity), `cef_log.txt` (Chromium),
  `gameprocess_log.txt` (Windows pids of a launched game),
  `gameoverlay_renderer.txt` (one file, rewritten by every process that
  loads the overlay renderer — copy it at once).
- **App status without the UI**: `curl 127.0.0.1:8764/status`,
  `:8764/windows` (every window the app owns, role, visibility). CDP
  liveness: `curl 127.0.0.1:8765/json/version`.
- **Killing steam.exe for a test**: any `ps | grep <pattern>` where the
  pattern also appears in your own shell line matches and kills your own
  script. The self-match-proof form is
  `ps ax -o pid=,command= | awk '$2 ~ /^C:/ && /Steam.exe/ && /silent/ {print $1; exit}'`
  (field 2 must be a `C:\` path); verify with `ps -p $PID` after.
- **Watchers need deadlines**: `tail -f | grep -m1` hangs forever when the
  line never comes. Use an epoch-seconds loop
  (`deadline=$(($(date +%s)+150))`; zsh's `$SECONDS` is a float and breaks
  `[ -lt ]`).
- **Do not run `xcodebuild test` while the live app runs**: the test host
  runs app code and has knocked the healthy client over. Build with `build`;
  test when the client is stopped.
- **Two apps, two bottles**: `/Applications/Sevoflurane.app` is a Release
  build; the dev build lives in
  `~/Library/Developer/Xcode/DerivedData/Sevoflurane-*/Build/Products/Debug/`
  and its bundled `sevo` is at `Contents/Helpers/sevo`. Launch the one you
  mean by full path or the audits are not comparable.
- **Worktrees**: a branch cut from `origin/main` can lag local `main` — push
  first, or `git worktree add -b <branch> <path> main`.

## Reporting bugs

Use the issue templates: one for Steam and the app, one for a game, one for
a feature. Every report wants the diagnostics zip — **Settings › About › Save
Diagnostics…** or `sevo diag` — which holds the app's logs, a `sevo doctor`
report, the active engine's `engine-info.json`, the bottle's env files, the
game launcher bundles, Steam's own bootstrap, connection, webhelper,
game-process and console logs, this month's run records with the logs the
games in them wrote for themselves, and the last two days of crash reports
from the engine's processes. `--no-steam-logs` leaves Steam's own logs out. The Wine
log already carries errors and exceptions for every launch; turn on Settings ›
Engine › Log every library a game loads (`sevo bottle config wine-debug on`)
only when a game fails to start and the library it could not resolve is the
question.

A game problem is fixed by running the game; a game the maintainer does not
own is asked for in the issue, as a gift copy or a donation that covers it.

## Pull requests

The template asks who wrote the change and how it was verified. A change
written with an agent says so, names the model, and says whether a human
attended the session; that is read, not held against anyone. What is held
against a PR: changes nobody ran, comments that narrate history or plans
instead of describing the code, and unrelated edits in the same diff.

Comments say what the code does and why, in the present tense. A negation
earns its place only when it names the wrong belief it corrects.
