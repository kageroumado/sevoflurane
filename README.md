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
  assistant, `App/` supervision, logging, menu bar, `Support/` shared system
  access (bottle paths, ports, subprocesses)
- `Sevo/` + `Package.swift` — the `sevo` CLI and MCP server (SwiftPM
  executable sharing the app's own lifecycle/CDP sources; `swift build`)
- `Spike/` — scratch probes kept only while they still answer a question the
  Swift tools cannot; provisioning, CDP and the boot surface all live in
  `sevo` now
- `Site/` — the landing page (not yet deployed)
- `Mockups/` — self-contained HTML design mockups (open in a browser)

`Docs/` and `HANDOFF.md` are untracked local working notes (investigations
with machine-specific evidence, session handoffs, the living release plan);
the durable architecture lives in `SPEC.md`.

## Running (dev)

Requirements: macOS 26+, Apple Silicon, Xcode 26+, CrossOver (14-day trial
works; the first-run assistant creates the bottle and installs Steam itself).

1. Build and launch the app — first run walks through setup; after that the
   app starts the bottled client with CDP on :8765, boots Steam's UI through
   the in-process bridge, and supervises from there
2. Diagnostics: `sevo doctor` (below) · event log at
   `~/Library/Logs/Sevoflurane.log` · `sevo eval '<js>'` evaluates in the page

Quitting the app shuts the bottled client down with it — nothing from the
bottle outlives Sevoflurane.

## `sevo` — the CLI

`swift build` produces `.build/debug/sevo` (`sevo install-cli` symlinks it
into `/usr/local/bin`). One management surface for terminals and agents:

```
sevo doctor [--json]        environment diagnosis, one ✔/✖ line per check
sevo status [--json]        engine · bottle · client · bridge · app, one line
sevo client start|stop|restart|update|pin|unpin
sevo recover [--deep]       the wedge playbook; --deep adds cache purge + repair
sevo app list|info|launch|terminate|install|verify|uninstall
sevo downloads status|pause|resume|throttle KBPS
sevo eval 'JS' · sevo cdp 'JS' [TARGET] · sevo logs [--tail N] [-f]
```

`--json` everywhere for scripts; exit codes: 0 ok · 1 failed · 3 not
provisioned · 4 client unreachable. When the app is running, mutating verbs
route through its supervisor (one owner for the restart ladder); when it
isn't, `sevo` drives the same lifecycle code directly.

### MCP: ask your agent to fix your Steam

`sevo mcp` is a stdio MCP server exposing the same verbs as typed tools
(plus `sevo://status`, `sevo://doctor`, `sevo://log`, `sevo://library`
resources). Claude Desktop / Claude Code config:

```json
{ "mcpServers": { "sevoflurane": { "command": "sevo", "args": ["mcp"] } } }
```

Things that just work from an agent chat: "why won't Steam start" (doctor →
recover), "install Hades and launch it" (library_list → app_install →
downloads_status → app_launch), "my download is stuck" (downloads_status →
recover). `eval_js` is only exposed with `SEVO_MCP_ALLOW_EVAL=1` in the
server's environment.

## Contributing

See `CONTRIBUTING.md` — start with SPEC.md's fidelity rules; most non-obvious
bugs here are a violation of one of them.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
