# sevobench

Repeatable measurements of what the app and the engine cost, for comparing one
build or setting against another. Stdlib Python; drives `sevo`, the control
port, and the two logs the report zip carries.

```zsh
python3 Tools/bench/sevobench.py --label baseline --iterations 3 launch
python3 Tools/bench/sevobench.py --label baseline idle --seconds 120
python3 Tools/bench/sevobench.py --label baseline --iterations 3 game 367520 --seconds 60
python3 Tools/bench/sevobench.py report --labels baseline candidate
```

Every run appends one JSON line to `~/Library/Application Support/Sevoflurane/Bench/<scenario>.jsonl`
(`SEVOBENCH_OUT` moves it). `report` prints medians, min and max per label.

## Scenarios

**launch** — quits the app (⌘Q semantics: the bottle comes down), waits `--settle`,
opens it, and polls `sevo status --json` until `health` is `healthy`. Records the
wall time, the boot milestones from the app log (client launched, client back,
services ready, healthy, window opened, and the app's own `boot audit` figure),
and the CPU seconds the app and the daemon spent getting there.

**idle** — the app healthy with no game window. Samples every second for `--seconds`.
CPU per process group comes from `cputime` deltas over the window, so it is exact
rather than the decayed `%CPU` column; memory is the peak RSS per process; GPU is
the whole machine's utilization from IOAccelerator (an animated wallpaper or another
app shows up in it — note the host in `host.load1m`).

**game** — `sevo app launch <appid>` (its JSON observation is kept), `--warmup`
seconds for loading, then a `--seconds` sampling window, then `sevo app terminate`.
From the Wine log's provenance lines: the renderer that was staged, time to the first
presented frame, and with Debug mode on, presented frames per second over the last
10 s interval before the window closed (`d3dmetal posted/executed`, which excludes
loading). The run record is attached. Because the game is terminated rather than
quit, its run record reads `crashed — exit 1` and the engine prints no `exit presents`
line; that is the harness, not the game.

## Which processes count

The app, the daemon, `wineserver`, and every Wine process whose working directory
or open files sit under `…/Sevoflurane/Bottles/` or `…/CrossOver/Bottles/`. A Wine
process from another prefix on the machine is not the app's cost and is skipped.
Labels: `app`, `daemon`, `wineserver`, `steam`, `steamservice`, `webhelper:<type>`,
`wine:<exe>`; `cpu_pct` sums the webhelper and wine families.

## Reading a comparison

Run the baseline at least three times before changing anything: the spread between
identical runs is the noise floor, and a change smaller than it is not a result.
Keep Debug mode the same across labels (it costs a little and adds the per-10 s
present counters). Keep the renderer, window mode and upscaler the same too;
`host.engine`, `host.app` and `host.debug` are recorded so a mixed set is visible.
