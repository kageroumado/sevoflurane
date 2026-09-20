# Playtesting Sevoflurane

How to run a session so that what you see can be traced to what the app and the
engine did. Follow it for a planned playtest; for a single bug, the issue
templates ask for the subset that matters.

## Before you start

1. **Nothing, for the logs.** The Wine log always carries `err+all,+pid`:
   every subsystem's errors, exceptions as they are dispatched, and the process
   id on every line, so a game that exits in two seconds leaves a trail without
   anyone having turned anything on. Every launch also writes a run record —
   what it ran on, how long it lasted, how it ended — which `sevo runs` prints
   and the report zip carries.

2. **Debug mode, for a planned session.** The menu bar's ⋯ menu › *Debug Mode*,
   or:

   ```bash
   sevo debug on      # sevo debug status; sevo debug off
   ```

   It turns on everything this protocol used to ask for by hand: every library
   a game loads, the renderer's own errors in a file of its own, the engine's
   frame trail, a window inventory whenever a window comes or goes, and a log
   written line by line, so the last line before a crash is on disk. The app
   half is on at once; the engine half reaches the client and its games at the
   next Steam start, so restart Steam from the menu bar — the menu item says so
   while a client is up.

   Nothing about it is remembered. It is off at the next launch whatever
   happened to this one, a force quit included, and the logs stop growing with
   it. Leave it on for the whole session; the report is what reads it.

   On a build without Debug mode, the manual equivalent is Settings › Engine ›
   *Log every library a game loads* (`sevo bottle config wine-debug on`), which
   also applies at the next Steam start and has to be turned off by hand.

3. **Note the renderer in force.** Settings › Graphics. A fresh Dormison bottle
   defaults to DXMT; D3DMetal is a choice. Every finding about a game needs the
   renderer that answered it, and a renderer switch from the menu bar restarts
   Steam, so write the time down.

4. **Note the window mode.** Settings › Engine › Picture › *Resizable windows*.
   The default covers games that run in a window; a game that covers the screen
   needs *Fixed-size and full-screen* before it can be moved or resized.

5. **Keep the app running.** Quit it with ⌘Q, never Force Quit, unless force
   quitting is the thing under test. A force-quit leaves the bottle running with
   nobody supervising it; that is a known limitation, not a finding.

## During the session

Write a timestamped line for every action and every verdict as you go. The logs
carry times to the millisecond; a verdict without a time cannot be matched to
them. `date '+%F %T'` in a terminal is enough.

Useful probes while the app is up, none of which disturb it:

| Question | Command |
|---|---|
| What state does the app think it is in? | `sevo status --json` |
| Which windows exist, where, and are they visible? | `curl -s localhost:8764/windows` |
| Which game window is up? | `curl -s localhost:8764/game/window` |
| What does Steam think is running? | `sevo cdp 'JSON.stringify(SteamUIStore.RunningApps.map(a=>a.appid))'` |
| The last 50 app log lines | `sevo logs --tail 50` |
| The Wine log, following | `sevo logs --wine -f` |
| Is Debug mode on, and where does it apply? | `sevo debug status` |
| Put Steam's window away, then bring it back | `curl -s -X POST localhost:8764/steam/close`, then `curl -s -X POST localhost:8764/steam/show` |

`curl localhost:8764/…` answers even when the app's window is frozen, because
the control server is its own listener. If the app stops responding, run
`sample Sevoflurane 5 -file ~/Desktop/sevoflurane-hang.txt` before killing it;
the sample is the only record of where the main thread was.

Testing supervision: kill Steam, not the app. `sevo client force-quit` or
`pkill -f 'Steam.exe -silent'` are the tests; the app must notice and restart
it. Killing the app tests something else.

## After the session

1. **Save the report.** Settings › Diagnostics › *Diagnostics archive*, or from a
   terminal:

   ```bash
   sevo diag --output ~/Desktop
   ```

   It carries Steam's own logs from the bottle (`gameprocess_log.txt` is the
   only place a game's exit code is recorded), the app log, the Wine log, the
   windows log (one line per process and window from the engine, whether or
   not the app ever saw a window), the bottle's env files, the launcher
   bundles, this month's run records, the renderer's own log if Debug mode was
   on, `sevo doctor`, and two days of crash reports.

2. **Check that the game's own log is in the zip.** The report carries this
   month's run records under `runs/`, and under `games/<appid>/` the logs each
   run's game wrote: Unity's `Player.log`, Unreal's `Saved/Logs` and
   `Saved/Crashes`. Paths in them are rewritten before they go in.

   A game with its own launcher writes wherever the launcher decided to;
   collect that one by hand if the game failed.

3. **Set the renderer back** if you changed it. Debug mode needs nothing:
   quitting the app ends it. *Log every library a game loads*, if you used that
   instead of Debug mode, is a setting and stays on until you turn it off.

## What the report can and cannot say

The report names no account. Crash reports and env files carry paths under your
home folder, so your short user name is in them; review before sharing. It
cannot say what you clicked, which is why the timestamped notes matter, and it
names the library a game failed to load only when Debug mode — or *Log every
library a game loads* — was on for that launch.

## Filing

One issue per finding, using the templates. A game that fails is a
[game issue](.github/ISSUE_TEMPLATE/2-game.md); Steam, a window, the menu bar
or the app itself is a [Steam or app issue](.github/ISSUE_TEMPLATE/1-steam-or-app.md).
Attach the report zip and, for a game, its own log from step 2.
