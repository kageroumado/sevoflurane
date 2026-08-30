# Contributing to Sevoflurane

Thanks for looking under the hood. A few things make this codebase easier to
work on than it first appears — and a few rules keep it that way.

## Orientation

- `Sevoflurane/` — the app. `Web/` hosts Steam's UI and windows; `Bridge/`
  is the in-process page↔client bridge; `App/` is supervision, logging, and
  the menu bar.
- `Spike/` — scratch probes. Provisioning, CDP evaluation and client
  lifecycle are the Swift `sevo` (`swift build`).
- `Mockups/` — self-contained HTML mockups; open them in a browser.

## Building

Xcode 26+, macOS 26+, Apple Silicon. Open `Sevoflurane.xcodeproj`, build the
`Sevoflurane` scheme. To actually run against Steam you need a CrossOver
bottle with Steam installed (`sevo setup` builds one headlessly, and the
app's first-run assistant does the same with a window around it).

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

1. **The supervisor owns the client lifecycle.** Nothing else may launch or
   kill bottle processes; new recovery behavior goes through its ladder.
2. **Steam's watchdog dialog is a symptom, never a control surface** — the
   app detects and recovers; it does not click Wine dialogs.
3. **US English** in code, comments, and strings. DocC comments on public
   interfaces. Split long functions instead of adding section comments.
4. **Logs are the product too.** User-visible failures must land in the
   event log (`~/Library/Logs/Sevoflurane.log`) with enough context to act
   on.

## Reporting bugs

Attach `~/Library/Logs/Sevoflurane.log` and the output of
`sevo doctor --json` (build it with `swift build` → `.build/debug/sevo`;
redact nothing — it contains no account data). If a game is involved, say
which appid and whether it runs under plain CrossOver.
