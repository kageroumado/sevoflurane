# Sevoflurane

**Steam for macOS, natively.** Your whole Steam library in a real Mac app —
native windows, the real macOS menu bar, Retina-sharp, quiet in the menu
bar — while the Windows Steam client that makes it possible runs invisibly
in a Wine bottle. It keeps doing what it's good at (downloads, installs,
ownership, launching games); everything you see and touch is macOS.

Named for the inhalational anesthetic: a drug delivered as vapor, famous for
smooth, fast, non-irritating induction — which is the product promise,
applied to Steam. The anesthesia machine color code for sevoflurane is
yellow; so is the accent color.

> **Status: pre-release.** The core works — Steam's own UI rendering in
> native windows against the bottled client, installs, launches, and a
> supervisor that heals hangs automatically — and is being hardened for a
> first public build. `Docs/release-plan.md` (untracked working notes)
> tracks the road to 1.0.

## How it works, in one paragraph

The Windows Steam client runs headless in a CrossOver bottle
(`-silent -cef-enable-debugging`). Steam's UI is a plain web app that only
needs a `SteamClient` binding; Sevoflurane serves that bundle into native
WKWebViews with a shim whose calls are replayed into the client's real
`SharedJSContext` over the Chrome DevTools Protocol, and whose protobuf
transport is relayed around CDP through a socket the client's own context
opens. Every window Steam creates is adopted into a real `NSWindow`. The
full architecture — and the fidelity rules that keep it honest — is
`SPEC.md`.

## Layout

- `SPEC.md` — the architecture: hosting Steam's UI, the bridge, native
  chrome, engine strategy, and the lsteamclient endgame
- `Sevoflurane/` — the app (Swift 6): `Web/` hosts Steam's UI and windows,
  `Bridge/` is the in-process page↔client bridge, `Setup/` the first-run
  assistant, `App/` supervision, logging, menu bar
- `Spike/` — Python reference implementations, all ported into the app
  (`bridge.py` → `Bridge/`, `lifecycle.py` → `Setup/Provisioner` +
  `App/ClientSupervisor`); `sevo.py` (diagnostics CLI) is the one still worth
  running on its own
- `Site/` — the landing page (not yet deployed)
- `Mockups/` — self-contained HTML design mockups (open in a browser)

`Docs/` and `HANDOFF.md` are untracked local working notes (investigations
with machine-specific evidence, session handoffs, the living release plan);
the durable architecture lives in `SPEC.md`.

## Running (dev)

Requirements: macOS 26+, Apple Silicon, Xcode 26+, CrossOver (14-day trial
works; the first-run assistant creates the bottle and installs Steam itself).

1. Build and launch the app — first run walks through setup; after that the
   app starts the bottled client with CDP on :8081, boots Steam's UI through
   the in-process bridge, and supervises from there
2. Diagnostics: `python3 Spike/sevo.py doctor` · event log at
   `~/Library/Logs/Sevoflurane.log` · `curl -X POST --data '<js>'
   http://127.0.0.1:8762/__eval` evaluates in the page

Quitting the app shuts the bottled client down with it — nothing from the
bottle outlives Sevoflurane.

## Contributing

See `CONTRIBUTING.md` — start with SPEC.md's fidelity rules; most non-obvious
bugs here are a violation of one of them.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
