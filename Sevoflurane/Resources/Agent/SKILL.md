---
name: sevoflurane
description: Run, debug and benchmark Windows games under Sevoflurane with its `sevo` CLI or MCP server. Use when launching or stopping a Steam game or an added Windows program in Sevoflurane's bottle, when a game crashes, hangs, shows a black screen or runs slowly, when changing a game's renderer, upscaler or DLL overrides, when Steam itself is stuck, when making a diagnostic run or a frame-rate comparison, when reading run records, frame traces or collected crash reports, when reporting how a game ran to the community database, or when writing a bug report for Sevoflurane.
---

# Sevoflurane

Sevoflurane runs Windows games on macOS. It keeps a Steam client in a Wine
bottle, runs it on an engine (Dormison, its Wine build, or CrossOver), runs
Windows programs added outside Steam (Quick Launch), and records every launch. `sevo` is its command line. It lives in the app at
`Sevoflurane.app/Contents/Helpers/sevo`, and Settings › General links it to
`/usr/local/bin/sevo`. `sevo mcp` serves the same verbs over MCP.

Every verb prints what it observed. Add `--json` for machine-readable output.
`sevo <verb> --help` documents each verb, and `sevo diag --help` has this guide
in short.

## Key commands

| Command | What it does |
|---|---|
| `sevo doctor` | Diagnoses the whole environment, one line per check. Run it first when anything is wrong. |
| `sevo status` | Engine, bottle, client, bridge, supervision and app, in one line. |
| `sevo app list` / `sevo app info <appid>` | The library, and one game's overview. |
| `sevo app launch <appid>` | Launches through Steam and waits for the game's window. |
| `sevo app terminate <appid>` | Stops a game — its processes first, then Steam's record — and waits for it to go. |
| `sevo app config <appid> [key] [value]` | A game's own settings: `renderer`, `upscaler`, `windows`, `hud`, `fps`, `overlay` (1-3: frame rate, frame time card, plus CPU/GPU/power/temperature), `fps-limit` (off or 30-120), `fps-graph`, `menu-bar` (a program's menus in the macOS menu bar), `dll`, `env NAME=value` (a variable the game starts with), `processors`, and more. With no key it prints every setting and the level it comes from. |
| `sevo app repair-dll <appid> <dll>` | For "X.dll was not found": installs the package that carries it and pins the fix to that game. |
| `sevo program list` / `launch <id>` / `add <path>` | Windows programs added outside Steam. Their ids start at 2000000000 and work with `sevo app config`. |
| `sevo hoyo status <folder>` / `update <folder>` / `verify <folder> [--repair]` / `install <game> <folder>` | Genshin Impact, Honkai: Star Rail and Zenless Zone Zero from HoYoPlay's servers, without HoYoPlay. MCP: `hoyo_list`, `hoyo_status`, `hoyo_verify`, `hoyo_update`. Star Rail updates but does not start under Wine. |
| `sevo bottle config [key] [value]` / `sevo bottle deps` | Defaults for every game, and the Windows runtimes and fonts installed in the bottle. The key `msync` switches msync+, Dormison's fork of CrossOver's msync. |
| `sevo engine list` / `use <name>` | Installed engines, and the one the next client restart boots. |
| `sevo runs` | The last launches: what each ran on, how long, how it ended, and the recognized failure. |
| `sevo perf list` / `compare` / `report` / `label` | Frame-time traces: list them, compare configurations, chart them, name them. |
| `sevo report <run> --verdict <v>` | Tells the community database how a run went: `plays`, `plays-with-fixes`, `launches` or `fails`, with an optional `--note`. |
| `sevo diag on` / `off` / `status` / `save` | The diagnostic level, and the zip for a bug report. |
| `sevo logs [--wine] [-f]` | The event log, or Wine's own output. |
| `sevo debug on` / `off` | Records everything until the app quits. Needs the app running. |
| `sevo streamer on` / `off` / `status` | Streamer Mode: Steam's windows show a chosen name and picture, no wallet balance, and friends as AI models. A running app reloads Steam's windows to apply it. |
| `sevo client restart` / `sevo recover [--deep]` | Restarts Steam, or brings a stuck client back; `--deep` also clears its web cache and repairs it. |
| `sevo sync sweep [--json]` | msync+'s lost-wake sweep: wakes threads left asleep on an available object (a game that exited mid-set can strand steam.exe's main thread) and names the object and its holders. Safe with a game running; recover runs it before restarting. |
| `sevo daemon repair` | Re-registers the background helper when it will not start. |
| `sevo storage [--games]` | What Sevoflurane, the bottle and each game occupy. |
| `sevo holds` / `sevo orphans` | What keeps the display awake, and Wine processes whose server is gone. |

## Making a diagnostic run

1. **Set the level before launching.** `sevo diag on` sets level 1, and
   `sevo diag on --level 2` sets level 2. A level reaches each game at its
   next launch, and Steam does not need restarting.
   - **0**, always on: the run record, the frame trace, the event log, Wine's
     errors, and a collected report after a crash or a stall kill. It costs
     nothing measurable.
   - **1** adds Wine's `+seh` exception channel, the DXMT, DXVK and D3DMetal
     logs, and a collected report after every run. Turn it on before
     reproducing a bug.
   - **2** adds `+loaddll,+module`, the presentation, presenter and graphics
     logs, whole minidumps, the machine's state every 10 s in the event log,
     and the report compressed. It turns itself off after one run.
2. **Launch with `sevo app launch <appid>`**, which opens a run record.
   `sevo run <exe>` starts a program with no record, trace or report.
3. **Play at least 60 s past loading, in a scene you can return to.** Loading
   and shader compilation fill the first seconds of every trace.
4. **Change one thing per comparison.** Change the renderer, upscaler,
   engine or tuning between configurations, and run each at least twice.
5. **Label what the record cannot see.** A setting inside the game or a
   different scene looks identical to the record, so name it:
   `sevo perf label 1 "vsync off"`. Here `1` is the newest run in `sevo perf list`.
6. **Compare** with `sevo perf compare --game <appid> --last <n> --skip 20`.
   - The first configuration is the baseline. Each other one shows mean ±
     standard deviation over its runs for average fps, 1 % low and p99 frame
     time, then a verdict for average and for 1 % low.
   - The verdict gives the change in percent and its 95 % interval. "Welch p"
     means Welch's t-test over runs, which needs two or more runs per side.
     "block bootstrap" means one side had a single run, which is weaker
     evidence.
   - "higher" or "lower" means the interval excludes zero. "no measurable
     difference" means it does not.
   - `sevo perf report --open` draws the same numbers as an HTML page with
     the frame-time series.
7. **Save the zip right after the problem** with `sevo diag save`. It
   collects crash reports from the last 48 h and run records from this month.
8. **`sevo diag off`** when done.

## What records a run, and where it lands

| Part | What it records | Where | Read it with |
|---|---|---|---|
| Run record | Engine, renderer, tuning, upscaler, first window, duration, exit, last exception, renderer notes, frame-rate summary, busy threads while focused (`threads`; a game spinning one per processor is offered a `processors` cap) | `~/Library/Application Support/Sevoflurane/Runs/<yyyy-MM>.jsonl` | `sevo runs [--json]` |
| Frame trace | Every frame's time from the driver's present counter, one CSV per run (Dormison) | `…/Sevoflurane/Runs/traces/`; labels in `labels.json` there | `sevo perf` |
| Stall watch | Each process's CPU time every 2 s. After 15 s with no CPU and no present it releases, continues, then kills the game | the run record's exit, `killed after a stall` | `sevo runs` |
| Collected report | Wine's exception trail, macOS `.ips` files, Unreal/Unity/NW.js logs, Steam's logs, `manifest.json` | `~/Library/Application Support/Sevoflurane/Reports/<run>/` | Finder, the Reports window |
| Known failures | Failures this project has diagnosed, matched to a record | under each line of `sevo runs`; `known_failure` in `--json` | `sevo runs` |
| Event log | What the app and `sevo` did | `~/Library/Logs/Sevoflurane.log` | `sevo logs` |
| Wine log | Wine's stderr at the level's channels | `~/Library/Logs/Sevoflurane-wine.log` | `sevo logs --wine` |
| Presenter log | `sevo:presenter` lines in the Wine log | the Wine log | level 2, or `PresenterLog=Y` under `HKCU\Software\Wine\Mac Driver` |
| Diagnostics zip | Everything above plus doctor, host and engine identity, redacted | `~/Desktop/Sevoflurane-report-<time>.zip` | `sevo diag save` |

**Redaction.** Everything in the zip and in a collected report passes through
redaction:

- a path under a home directory becomes `~`, and so does the bottle's Windows
  user;
- this Mac's names become `<host>` and the account's name becomes `<user>`;
- Steam ids become `<steamid>`, and persona names in collected reports become
  `<persona>`.

## The community game database

With sharing on (Settings › General › Community), every run that drew a frame
or lasted 20 s is sent to the public Sevoflurane game database after it
closes: appid, executable name, engine, renderer, settings, resolution, frame
rates, and the Mac's model, chip, GPU cores and memory tier. Requests are
signed by a key in the Mac's Secure Enclave. `sevo stats` shows whether
sharing is on, the install id and the queue; `sevo stats preview` prints
exactly what the last run would send, `sevo stats reports` lists the verdicts
sent, and `sevo stats delete` takes back everything this Mac shared.
`sevo report` adds a verdict and note to a run. A good diagnostic run is also a good
data point there: 60 s past loading, one configuration, labeled.

## Common failure signatures

- **`unity-exit-1-no-window`**: a Unity game quit with status 1 and never drew
  a window. It failed in its graphics device or in Mono. Its `Player.log`
  (under `games/` in the zip) says which.
- **`unreal-exit-3`**: Unreal quit with status 3, from an uncaught C++
  exception. The callstack is in `Saved/Logs` and `Saved/Crashes`.
- **`dxmt-dropped-compute`**: a shader failed to convert to Metal, so a pass
  never ran. Expect a black screen or a missing effect. Try another renderer:
  `sevo app config <appid> renderer <name>`.
- **`killed after a stall`**: the game used no CPU and presented nothing for
  15 s, and stayed that way for 15 s more after the watch released it. A
  stall kill always collects a report, under `Reports/`.
- **`ended by the user while it was not responding`**: the window stopped
  answering, and the person closed it.
- **`fps: null`** in a record: the run never presented a frame through a
  Metal layer, so nothing counted its frames.
- **`no runs with a frame trace yet`**: traces come from Dormison
  (`sevo engine` switches the engine).
- **`Bad CPU type`** from every Wine process: Rosetta is missing. Run
  `softwareupdate --install-rosetta`.
