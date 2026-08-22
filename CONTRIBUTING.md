# Contributing to Sevoflurane

Thanks for looking under the hood. A few things make this codebase easier to
work on than it first appears — and a few rules keep it that way.

## Orientation

Read `SPEC.md` first: it explains the architecture (Steam's own UI hosted in
native WKWebViews against the bottled Windows client over CDP) and the
fidelity rules that everything depends on. The non-obvious bugs in this
project are almost always a violation of one of those rules.

- `Sevoflurane/` — the app. `Web/` hosts Steam's UI and windows; `Bridge/`
  is the in-process page↔client bridge; `App/` is supervision, logging, and
  the menu bar.
- `Spike/` — Python prototypes and probes. `lifecycle.py` (client
  provisioning/lifecycle) and `sevo.py` (management CLI) still stand alone;
  they are being absorbed into Swift.
- `Mockups/` — self-contained HTML mockups; open them in a browser.

## Building

Xcode 26+, macOS 26+, Apple Silicon. Open `Sevoflurane.xcodeproj`, build the
`Sevoflurane` scheme. To actually run against Steam you need a CrossOver
bottle with Steam installed (`Spike/lifecycle.py provision` builds one
headlessly).

## Rules of the road

1. **Don't break the fidelity rules** (SPEC.md): mirror the real client's
   shape, carry binary as base64 envelopes with the view type, never
   stringify a rejection object, route callbacks to the page that registered
   them, and never force Steam Deck identity.
2. **The supervisor owns the client lifecycle.** Nothing else may launch or
   kill bottle processes; new recovery behavior goes through its ladder.
3. **Steam's watchdog dialog is a symptom, never a control surface** — the
   app detects and recovers; it does not click Wine dialogs.
4. **US English** in code, comments, and strings. DocC comments on public
   interfaces. Split long functions instead of adding section comments.
5. **Logs are the product too.** User-visible failures must land in the
   event log (`~/Library/Logs/Sevoflurane.log`) with enough context to act
   on.

## Reporting bugs

Attach `~/Library/Logs/Sevoflurane.log` and the output of
`python3 Spike/sevo.py doctor --json` (redact nothing — it contains no
account data). If a game is involved, say which appid and whether it runs
under plain CrossOver.
