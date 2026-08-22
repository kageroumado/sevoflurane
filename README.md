# Sevoflurane

A native macOS frontend for Steam running in a CrossOver bottle. The Windows Steam
client runs headless in the bottle and keeps owning what it's good at — downloads,
installs, ownership/DRM, game launch — while everything the user sees and touches is
native macOS. No translated Chromium, no steamwebhelper windows, no blurry
non-retina UI.

Named for the inhalational anesthetic: a drug delivered as vapor, famous for smooth,
fast, non-irritating induction — which is the product promise, applied to Steam.
The anesthesia machine color code for sevoflurane is yellow; so is the accent color.

## Layout

- `SPEC.md` — the full spec: MVP scope, architecture, and the lsteamclient endgame
- `HANDOFF.md` — living session handoff: current state, verified behavior, next work
- `Docs/release-plan.md` — the road to 1.0: milestones R1–R5, risks, estimates
- `Docs/resilience-spec.md` — steamwebhelper hangs, Steam's RescueDialog watchdog,
  and the auto-recovery design
- `Docs/onboarding-spec.md` — download-drag-launch self-setup: engine install,
  bottle wiring, dock hygiene, updates
- `Docs/cli-mcp-spec.md` — the `sevo` CLI and MCP server design
- `Sevoflurane/` — the macOS app (Swift 6, WKWebView-hosted Steam UI, menu-bar app)
- `Spike/` — the Python bridge (`bridge.py`), client lifecycle (`lifecycle.py`),
  the `sevo` CLI prototype (`sevo.py`), the `SteamClient` shim
  (`steamclient_shim.js`), and probes; being ported to Swift
- `Docs/steam-client-hangs.md` — hang investigation with evidence
- `Mockups/library.html`, `Mockups/onboarding.html` — HTML mockups of the library
  UI and the first-run assistant (open locally in a browser)

`Docs/` and `HANDOFF.md` are local working notes (investigations with machine-
specific evidence, session handoffs, the living release plan) and stay
untracked; the durable architecture lives in `SPEC.md`.
- Research foundation: the research notes
  (validated seams, prior-art survey, Steam client internals, Proton mechanism)

## Status

Steam's own desktop UI runs inside the app's native windows: library live from
the bottled client, macOS menu bar driving Steam's real menus, `steam://` and
file-open actions handled natively (no Wine windows). The Python bridge and
client supervision are next to move into Swift — `HANDOFF.md` has the ordered
list.

## Running (dev)

1. `python3 Spike/lifecycle.py start` — Steam up in the bottle with CDP on :8081
2. `cd Spike && python3 -u bridge.py > bridge.log 2>&1 &` — serves the UI + proxy
3. Launch the Sevoflurane app (Xcode or the Debug build); it loads
   `http://127.0.0.1:8762/`

Stop with `python3 Spike/lifecycle.py stop` — and expect to `kill` survivors;
see `Docs/steam-client-hangs.md` for why.
