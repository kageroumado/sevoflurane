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
opens. Every window Steam creates is adopted into a real `NSWindow`.

## Graphics, and the Rosetta clock

A Windows game on a Mac needs its Direct3D calls translated into Metal, and
which translator it gets is the single biggest lever on how it runs.
Settings › Graphics picks one for the bottle (the (i) beside it says the same
thing in place):

| Renderer | What it is | Reach for it when |
|---|---|---|
| **D3DMetal** | Apple's Game Porting Toolkit — Direct3D 11 **and 12** | The default here, and the only option that speaks DirectX 12 or drives MetalFX upscaling. |
| **DXMT** | Open-source Direct3D 10/11 straight to Metal ([3Shain/dxmt](https://github.com/3Shain/dxmt)) | DirectX 11 titles, especially on an older Mac; frame pacing is often steadier. |
| **DXVK** | Direct3D 9–11 through Vulkan and MoltenVK | A game refuses to draw on either Metal path, or needs Direct3D 9. |
| **Automatic** | CrossOver's per-game database, falling back to Wine's own `wined3d` | You would rather trust their QA than choose. |

CrossOver 26 carries D3DMetal 3.0 and DXMT 0.72 on top of Wine 11. The
built-in engine cannot ship D3DMetal — only Apple may distribute it — so
Settings › Graphics takes your own download of the
[Game Porting Toolkit](https://developer.apple.com/games/game-porting-toolkit/)
and installs it into the engine. Releases and betas sit side by side and the
newest is used unless you pick another; toolkit 4 is where Direct3D 12 meets
Metal 4.

**Rosetta is on a clock.** macOS 27 is the last release that carries it;
macOS 28 drops it in 2027, and everything above runs today as x86_64 under
Rosetta. CodeWeavers' answer is native ARM64 Wine with
[FEX](https://github.com/FEX-Emu/FEX) — their open-source x86 emulator — in
Rosetta's place; the first Mac ARM64 preview shipped 31 July 2026, aimed at
CrossOver 27 in early 2027.

What that means here: Sevoflurane itself is native and emulates nothing, so
whatever CrossOver makes the Steam client do, this app drives. The open
question is game performance. Apple Silicon has a hardware total-store-order
mode that the kernel switches on for Rosetta, and no ordinary process can ask
for it, so FEX has to emulate x86 memory ordering in software — cheapest
where threads are few, and games are not that. Correctness is expected;
per-title speed is unmeasured until the builds are real — unless Apple opens
that switch to more than Rosetta, which would close most of the gap at once.

DXVK upstream is alive (2.7.1, with commits through 2026); on a Mac what you
actually run is CrossOver's own build or [Gcenx/DXVK-macOS](https://github.com/Gcenx/DXVK-macOS),
whose ceiling is MoltenVK's Vulkan extension coverage rather than DXVK itself.


## Layout

- `Sevoflurane/` — the app (Swift 6): `Web/` hosts Steam's UI and windows,
  `Bridge/` is the in-process page↔client bridge, `Setup/` the first-run
  assistant, `App/` supervision, logging, menu bar, `Support/` shared system
  access (bottle paths, ports, subprocesses)
- `Sevo/` + `Package.swift` — the `sevo` CLI and MCP server (SwiftPM
  executable sharing the app's own lifecycle/CDP sources; `swift build`)
- `Spike/` — scratch probes kept only while they still answer a question the
  Swift tools cannot
- `Site/` — the landing page (not yet deployed)

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

See `CONTRIBUTING.md` — start with the fidelity rules; most non-obvious bugs
here are a violation of one of them.

## License

MIT. Not affiliated with Valve. Steam is a trademark of Valve Corporation.
