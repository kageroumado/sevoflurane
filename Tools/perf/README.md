# Performance tooling

## The smoke scenario

Launch the app with `SEVO_ENABLE_BENCHMARKS=1`, then:

```zsh
sevo benchmark                              # Library, Store, Friends × 5, quiet host
sevo benchmark --load 8                     # the same with 8 busy threads at the game's priority
sevo benchmark --load 8 --qos userInitiated # load that outranks the bridge queues
sevo benchmark --target store --iterations 2
```

`POST :8764/benchmark/smoke?iterations=&target=&load=&qos=` is the endpoint underneath.

What a run does before timing anything: brings the desktop forward, reads the page's
`document.visibilityState`, and — when the window is covered — suspends WebKit's occlusion
detection on the desktop for the run so animation frames keep coming (`desktopVisibility`
in the report says `visible`, `forced`, or `hidden`; a `hidden` run reports every step as
`skipped` instead of timing an invisible page). The Friends window is closed first so the
step measures a real popup open. `hostBefore`/`hostAfter` carry load average, thermal
state, free and compressed memory; `load` says what synthetic load ran.

Every sample carries `mainThread`: the main thread's queueing delay while the step ran,
measured by a user-interactive thread pinging the main queue every 16 ms. A
`maxDelayMilliseconds` that grows with `--load` is a priority inversion — the main
thread waited on work scheduled at or below the load's priority. Each ping over 50 ms is
also a `MainThreadStall` Point of Interest, so Instruments can show what every other
thread was doing at that instant.

## Signposts (subsystem `glass.kagerou.sevoflurane`)

| category | name | covers |
|---|---|---|
| Points of Interest | `Launch`, `PageBoot`, `DesktopAdopted`, `Healthy`, `ClientBack` | boot milestones |
| Points of Interest | `SmokeScenario`, `ScenarioStep`, `MainThreadStall` | the scenario and stalls seen during it |
| `supervisor` | `ProbeCycle`, `ClientProbe`, `PopupHide`, `ClientRestart`, `CrashLoopHygiene` | one health cycle and its parts; `PopupHide` opens one DevTools session per CEF popup target |
| `bridge` | `CDPConnect`, `CDPCall`, `PageEval`, `SteamClientCall`, `WebKitEval`, `CookieMirror`, `BrowserViewLoad`, `ServeAsset` | every hop between the page, the bridge, CEF, and WebKit |
| `system` | `Subprocess`, `WineWindowScan` | calls out of the process that a busy host slows down |
| `events` | `Log` | every EventLog line |

Record with `xcrun xctrace record --template 'System Trace' --all-processes` (or
`Time Profiler`) while `sevo benchmark --load N` runs; the `os_signpost` instrument
filtered to the subsystem lines the intervals up against thread states.

## Trace aggregation

Two stdlib-only scripts that turn `xctrace export` XML into per-process / per-thread tables.

```zsh
xcrun xctrace export --input capture.trace --xpath '//trace-toc/run[1]/data/table[@schema="thread-state"]' > thread-state.xml
python3 Tools/perf/agg_threadstates.py thread-state.xml 30        # System Trace: on-core time, wakeups, runnable time

xcrun xctrace export --input capture.trace --xpath '//trace-toc/run[1]/data/table[@schema="time-profile"]' > time-profile.xml
python3 Tools/perf/agg_timeprofile.py time-profile.xml 'Sevoflurane|WebKit|steam|Steam|wine'   # Time Profiler: hot frames per process
```

A 20 s all-process System Trace exports to ~1 GB of XML and aggregates in 4–5 min; a
30 s all-process Time Profiler export is ~200 MB. The numbers are only comparable between
runs with similar `hostBefore.loadAverage1m`.
