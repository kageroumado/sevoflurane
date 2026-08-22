# Sevoflurane — specification

*2026-08-09. Research foundation:
the research notes
— four-agent research pass + live experiments against the CrossOver 26.3 Steam bottle
on this machine. Every seam the MVP depends on was exercised there, not assumed.*

## Revised plan (2026-08-09, after the WebKit experiments)

**No custom UI at all.** Steam's UI bundle is a plain web app, and the decisive
experiment — serving the bottle's `steamui/` and loading it in WebKit — showed
it runs there with **one** error: `ReferenceError: Can't find variable:
SteamClient`. No syntax errors, no Chromium-only APIs, no missing features.
**WebKit is enough; embedding CEF is unnecessary.** Supplying a shimmed
`SteamClient` boots the app: React mounts and Steam's own stores come alive
(`g_PopupManager`, `g_ClanStore`, `g_LogManager`, …). So the app ships a menu
bar item and a window, and everything inside the window is Steam's — which also
means store, community, and friends come for free, since those are web too.

### What is proven (all executed locally)

| Finding | Evidence |
|---|---|
| WebKit parses/runs Steam's whole bundle | one `ReferenceError`, nothing else |
| A shim boots the app | React mounts; Steam's global stores initialize |
| Shim must mirror the real client's *shape* | desktop client has no `System.Audio` (Deck-only); a catch-all Proxy makes the UI call methods that don't exist — injecting a shape snapshot cut errors 11 → 2 |
| Calls, results **and live callbacks** round-trip | `Spike/bridge.py` replays shim calls into the real SharedJSContext over CDP; callbacks stream back through a `Runtime.addBinding` push |
| Boot surface is small | 88 calls across 21 namespaces, captured by `Spike/probe_steamui.py proxy` |
| The app is menu-bar-only | LSUIElement + `.accessory`; verified zero Dock presence while running |
| **The whole UI renders** | Steam's desktop window — chrome, nav, account, and the full 291-game library with art and playtime — drawn by Steam's bundle from live client data, at `devicePixelRatio = 2` |
| The transport socket refuses outsiders | a byte-identical handshake from a raw macOS socket gets 403; only the client's own context is admitted (`Spike/ws_handshake_probe.py` captured the real one) |

### The architecture this dictates

Steam's UI is **one JS context that renders its visible windows into popups it
opens itself**. The real client's main window is a popup named `SP Desktop`,
whose document is the same `index.html` (with `IN_CLIENT=true&USE_POPUPS=…`),
and the context renders React into it across documents.

WKWebView can host exactly that: `WKUIDelegate.createWebViewWith` hands back a
child web view built from the *same* configuration, so it shares one web
content process and the opener can script it as it does under CEF. The app is
then: hidden context web view + adopted popup web views in real windows.

**Current state (2026-08-10): the UI runs, in the app.** Steam's own desktop
window renders end to end inside a native `NSWindow` — menu bar,
STORE/LIBRARY/COMMUNITY/account nav, notifications, the signed-in account,
status bar, and **the full library**: 291 games, shelves, capsule art, Recent
Games with playtime, Play Next. All of it is the real client's data over the
bridge, drawn by Steam's own bundle, at native Retina
(`devicePixelRatio = 2`). Each popup Steam opens is adopted into a real window,
`SteamClient.Window` drives that window, and the app carries a macOS menu bar.

The boot stall was six independent bugs, not one; each is recorded with its
evidence in `HANDOFF.md`. Two consequences are architectural and belong here:

- **The transport socket is peer-gated.** `ws://localhost:<port>/transportsocket/`
  answers **403 to any connection originating outside the bottle** — a
  byte-identical handshake replayed from a raw macOS socket is still refused,
  so the gate is the connecting process, not a header. Only the client's own
  context may open it, so the page tunnels its transport through that context.
- **CDP cannot carry the hot path.** Driving the transport with a
  `Runtime.evaluate` per frame wedged steamwebhelper outright. The transport
  now runs over a WebSocket the client's context opens *to us*, frames
  length-prefixed by tunnel id. CDP is used only to bootstrap and to forward
  ordinary `SteamClient` calls.

Fidelity rules earned the hard way, all still load-bearing:
1. **Shape mirroring** — a catch-all Proxy made the UI call Deck-only methods
   (`System.Audio`) the desktop client lacks. Errors 11 → 2.
2. **Binary marshalling** — binary crosses as base64 envelopes that **carry the
   view type**, and the codec **recurses into plain objects**: a `Uint8Array`
   nested in an object was JSON-mangled, which hung `ParentalStore.Init()` and
   with it the entire pre-login stage.
3. **Rejection fidelity** — Steam rejects with objects the UI branches on
   (`{result: 2, message: 'Not found'}`); never stringify them.
4. **Callbacks are per-page** — callback ids must be page-unique and routed to
   the page that registered them. Broadcasting them let two pages run each
   other's handlers, which silently left stores unpopulated.
5. **A popup renders only once told it exists** — CEF posts `"popup-created"`
   to each new popup window and the UI defers all rendering into it until that
   arrives. Whatever hosts a popup must send it, and must inject the
   per-window `SteamClient` that CEF would otherwise provide.

### Native chrome — hide it, mirror it, reimplement it

Steam draws its own window chrome because under CEF it owns a borderless OS
window. Hosted in our app that chrome is wrong twice over: it duplicates the
macOS title bar, and its buttons drive a window manager we do not have. Four
different treatments, by kind:

**1. Window controls (close / minimize / maximize) — reimplemented, done.**
They route through `SteamClient.Window.*`, which now answers against a real
`NSWindow` (`Sevoflurane/Web/SteamWindow.swift`). The chosen cosmetic is the
*native* one, not the borderless one this spec originally leaned toward: the
window is `.titled` + `fullSizeContentView` with a transparent title bar, the
traffic lights float over Steam's own strip, and Steam's duplicate buttons are
hidden by CSS on `.TitleBar.title-area` — the one semantic class in that corner
of the DOM. Borderless was rejected once the strip was measured: Steam puts its
buttons top-*right*, so a borderless window would have left the top-left dead
and read as a port. The strip is inset 72px for the lights instead — an inset
that disappears once the menu strip moves to the macOS menu bar.

Heights have to agree: Steam gives its strip 32pt and a bare title bar is ~28pt,
so the window wants an empty `NSToolbar` with
`toolbarStyle = .unifiedCompact` to line the traffic lights up with Steam's own
row.

Dragging needed one non-obvious piece: **WebKit implements no part of
`-webkit-app-region`** — not the drag behavior, and not even the property in
`getComputedStyle`. The page reports the strip's empty stretch to the host and
an `NSView` hit test hands those rectangles back to AppKit.

**2. The menu bar (Steam / View / Friends / Games / Help) — mirror it.**
Each menu is a popup Steam opens itself (`Steam Root Menu`, `View Root Menu`,
`Friends Root Menu`, `Games Root Menu`, `Help Root Menu`). Measured: **all five
exist from boot**, created hidden, so the mirror can read them without opening
anything. Walk their rendered items, build the equivalent `NSMenu`, and on
selection dispatch a click back into the popup's DOM — `HTMLElement.click()`
reaches React even on a `display: none` element, so the in-window strip can be
hidden at the same time. Not started.

The end state is that the native menu is the *only* menu: Steam's strip hidden,
the traffic-light inset removed with it, and every item driven one to one. A
partial menu bar ships today: Sevoflurane / Edit / View / **Go** / Window.
`Go` drives Steam's own router directly
(`SteamUIStore.WindowStore.MainWindowInstance.Navigator`) rather than
`ExecuteSteamURL`, which runs inside the bottle's client and would navigate the
window *it* owns. The Edit menu is not decoration: WebKit routes ⌘C/⌘V through
the responder chain, so without it text editing in Steam's UI is dead.

**3. The toolbar cluster (broadcast, notifications, avatar + account, remote
display) — imitate.** These sit top-right and are ordinary Steam UI elements
backed by stores we already have live (notifications, the logged-in user,
broadcast state, Remote Play). Simplest first pass is to leave them in place;
the nicer end state is a native toolbar that reads the same stores, so the
window shows one chrome instead of two.

**4. Windows other than the desktop get their own treatment.** Steam names
every popup, and the name is the classification: `SP Desktop`, `SP BPM`,
`SP DesktopLoginWindow`, `SP Keyboard`, `SP Controller Configurator`,
`contextmenu_<n>`. Big Picture in particular wants a *real* title bar outside
the content rather than the desktop window's overlay treatment — it is meant to
run full screen, and the traffic lights otherwise sit on top of its own bar.

**`steam://` must not escape.** Steam's menus navigate the window to
`steam://open/about` and expect the host to intercept. WKWebView hands unknown
schemes to LaunchServices, which launches the Mac's own Steam.app, so the host
has to cancel those navigations in `decidePolicyFor` and dispatch them itself.

**Ordering.** (1) is done; (3) is cosmetic and can wait; (2) and (4) are the
highest-value polish and the most work.

### Steam Deck mode — don't force Deck identity

Since the 2023 Big Picture rewrite, **BPM *is* the Deck UI** — same bundle,
gamepad routes, reachable with `-gamepadui`. So rendering the gamepad routes
from our own assets gives the real Deck UI with no Deck ident at all.

Forcing identity is the wrong lever. `-steamdeck` / `steam_dev.cfg SteamDeck=1`
leak `SteamDeck=1` into launched games, which then self-nerf (30 fps caps,
forced low presets, hidden graphics menus — ValveSoftware/steam-for-linux#11947),
and Deck-only quick-settings panels are inert on non-Deck hardware.
`SteamClient.Apps.SetForceIdentAsSteamDeck` has **zero public documentation**
(0 GitHub code-search hits; absent from decky's typings) — our live enumeration
is ahead of the public record. Keep it as an experiment toggle only.

**Deck Verified badges need none of that**: the desktop client has shipped
"Show Steam Deck compatibility info" since 2023, and
`SteamAppOverview.steam_deck_compat_category` is on every app overview already
in our stores. Detailed per-test data, unauthenticated:
`store.steampowered.com/saleaction/ajaxgetdeckappcompatibilityreport?nAppID=<id>&l=english`
— which now also carries SteamOS, Steam Machine, and Steam Frame verdicts.

### macOS compatibility data (for a "will it run here?" panel)

| Source | Use | License |
|---|---|---|
| AreWeAntiCheatYet `games.json` | hard gate — the `anticheats[]` list is the real macOS signal | **MIT, bundle it** |
| ProtonDB `/api/v1/reports/summaries/<appid>.json` | Wine-family ceiling; discount titles that are only Gold *because* of Proton's EAC/BattlEye runtimes, which macOS lacks | ODbL dumps; live fetch + attribution |
| AppleGamingWiki Cargo `Compatibility_macOS` (crossover/wine/native fields; appid bridge via PCGamingWiki `Infobox_game.Steam_AppID`) | the mac-specific verdict when present | **CC BY-NC-SA 3.0 — NC matters if Sevoflurane is ever paid** |
| CodeWeavers compatibility DB | link-out on the detail view only — no API, no license to redistribute | proprietary |

### lsteamclient port: smaller than feared (phase 2)

Proton's bridge is **~10k hand-written lines against ~391k generated** (38:1),
and the generated half is platform-neutral. Critically, the macOS branch
already exists: `unixlib.cpp:738-746` has an `#ifdef __APPLE__` path that
dlopens `steamclient.dylib`, and the entire contract with Valve's proprietary
client is **7 flat exports** (CreateInterface, Steam_BGetCallback, …). No Linux
syscalls anywhere (zero epoll/futex/eventfd hits); the one `__linux__` block is
an X11 keysym table that compiles out.

The work is build integration, not porting: drop it into a CrossOver/Wine
source tree as `dlls/lsteamclient/`, add the loader redirection that sends a
game's `steamclient.dll` to the builtin, and replace `proton`'s env setup with
our launcher.

**Cheapest possible first experiment, no Wine involved:** a small native
x86_64 C program that dlopens Steam's `steamclient.dylib`, calls
`CreateInterface("SteamClient017")` → `CreateSteamPipe` → `ConnectToGlobalUser`
→ `GetISteamUtils` → `GetAppID` while the native Mac client runs. That
validates the whole native half — the only genuine unknown — in an afternoon.
Reference clones: Proton and kaon.

## What it is

Steam for macOS, the way Proton made Steam for Linux: the real client does the real
work, and the platform does the presentation. The Windows Steam client runs
**headless** inside a CrossOver bottle (`-silent`, windows never shown); Sevoflurane
is the native macOS surface over it — library, installs, downloads, launch — talking
to the in-bottle client over Chrome DevTools Protocol on localhost.

**The one-sentence architecture:** wineserver sockets are host loopback sockets, so
the in-bottle client's CEF debugging endpoint and its `SteamClient` JS API (48
namespaces: `Installs`, `Downloads`, `Apps`, `InstallFolder`, …) are directly
callable from a macOS process — no Wine code, no injection, no patched binaries.

### Why not just show the Steam UI in a native browser

`window.SteamClient` is injected by CEF only into trusted origins inside
steamwebhelper; Steam's React bundle is inert without it, and the browserless client
modes were removed in 2023. So steamwebhelper must keep running — but only as an
invisible backend appendage. It renders nothing; the retina/perf/jank failures are
all in the *compositing*, which never happens.

## Goals / non-goals

**Goals (MVP):** library browsing · install / uninstall / update with real progress ·
launch / terminate · bottle + client lifecycle management (install Steam, keep it
healthy, survive client updates) · `steam://` URL handling.

**Non-goals (MVP):** friends/chat, overlay configuration, workshop management,
Big Picture, controller config, store rendering beyond a WKWebView on the real
`store.steampowered.com`. Anti-cheat titles (EAC/BattlEye) get a "will not run"
badge — CodeWeavers' position is definitive; no vendor ships macOS/Wine modules.

---

## MVP — "headless bottle client + native cockpit"

### Components

1. **BottleManager** — locates (or creates, via CrossOver's CLI) the Steam bottle,
   installs/repairs the Windows Steam client (SteamSetup.exe bootstrapper), reads
   `steamapps/` state directly from `drive_c` for cold-start display before the
   client is up.
2. **ClientSupervisor** — launches
   `steam.exe -silent -cef-enable-debugging -devtools-port <random>` via
   CrossOver's `wine --bottle Steam --no-wait`, watches process health, performs
   graceful `-shutdown`, and re-attaches after client self-updates. Port fact
   confirmed by `strings steamclient64.dll`: `-devtools-port` → passed through as
   `--remote-debugging-port=%s`; well-known 8080 is avoidable.
3. **CDPBridge** — WebSocket client (`URLSessionWebSocketTask`) to
   `127.0.0.1:<port>`. Target discovery via `GET /json`; attaches to
   `SharedJSContext` (the privileged realm holding both the `SteamClient` API and
   the UI's MobX stores). `Runtime.evaluate` for calls; `Runtime.addBinding` +
   injected registration shims for subscriptions (`RegisterForDownloadItems`,
   `RegisterForAppOverviewChanges`, …). Reinjection watchdog à la Decky Loader:
   on webhelper restart, re-attach and re-register.
4. **SteamKitLayer** *(thin, typed)* — Swift wrappers over exactly the calls the MVP
   needs, nothing more (the full 48-namespace surface is community-typed in
   decky-frontend-lib; we bind ~15 methods):
   - Library: `appStore.allApps` snapshot + `RegisterForAppOverviewChanges`
   - Install: `Installs.OpenInstallWizard([appid])` /
     `SetAppList`+`SetInstallFolder`+`ContinueInstall` for promptless flow
   - Downloads: `Downloads.QueueAppUpdate`, `PauseAppUpdate`, `ResumeAppUpdate`,
     `RegisterForDownloadItems`, `RegisterForDownloadOverview`
   - Launch: `Apps.RunGame(appid, "", -1, 100)`, `Apps.TerminateApp`,
     `Apps.CancelLaunch`, `Apps.GetGameActionForApp`
   - Maintenance: `Apps.VerifyApp`, `InstallFolder.GetInstallFolders`
5. **Artwork** — served from disk: the bottle's
   `Steam/appcache/librarycache/<appid>/` holds the capsule/hero/logo assets the
   client already downloaded; fall back to
   `https://shared.steamstatic.com/store_item_assets/steam/apps/<appid>/` for
   missing entries. No scraping, no API keys.
6. **UI shell** — see "The SwiftUI question" below.
7. **URL handler** — Sevoflurane registers for `steam://`; `rungameid`/`install`
   deep-link straight to the corresponding SteamKitLayer calls.

### Login

First run: the real (Wine) login window is shown once — the only time translated UI
is ever visible — or, stretch goal, a native QR flow driven through
`SteamClient.Auth`. The session persists in the bottle; subsequent launches are
`-silent` and invisible.

### Failure modes the supervisor must own

- Client self-update restarts steamwebhelper → CDP targets vanish → reconnect loop
  with backoff, re-registration of all subscriptions.
- Update/EULA/login dialogs can appear unbidden → detect (window enumeration via
  CDP target list + Wine process args) and surface a native "Steam needs attention"
  affordance that reveals the real window rather than leaving a zombie.
- Valve churn on the JS surface: unversioned. Mitigation is institutional, not
  technical — Decky/Millennium/SFP absorb every breakage within days; track their
  repos. The MVP binds ~15 methods, so the blast radius per Steam update is small.

### The SwiftUI question

Maintaining a hand-built SwiftUI replica of Steam's library is the part flagged
as unreasonable, and the concern is right: that UI is a moving target and a taste
tax paid forever. Two mitigations, in order of preference:

1. **Local-HTML UI in a WKWebView** — the app's own UI is one HTML/JS file (the
   mockup in `Mockups/library.html` is written to be promotable to exactly this),
   backed by a Swift bridge (`WKScriptMessageHandler`) that pipes SteamKitLayer
   calls and store updates as JSON. One codepath from mockup → product; iteration
   is a browser reload; the native shell shrinks to window chrome + bridge +
   supervisor (~"as little app as possible").
2. **Thin SwiftUI cockpit** — if the HTML route chafes, the fallback is a
   deliberately small SwiftUI surface (grid, hero row, downloads strip) that
   renders MobX-derived state and never grows features. Either way the UI is a
   projection of one data model; the logic lives in the layers below.

### App shape

**Menu bar app** (like Steam's own tray behavior): `MenuBarExtra` with
`.menuBarExtraStyle(.window)` — or NSStatusItem + `.accessory` activation policy —
clicking the sevo-yellow glyph opens the library window. No Dock icon, no
CrossOver in the Dock, nothing in the app switcher unless the window is open.
Quitting the app (or the Mac sleeping into shutdown) triggers the supervisor's
stop sequence, so in-bottle Steam never outlives the app as a zombie.

### Provisioning & lifecycle (verified end-to-end 2026-08-09, throwaway bottle)

The whole cycle was executed in a scratch bottle (`SevoTest`) and works without
CrossOver's GUI ever running — `Spike/lifecycle.py` encodes it:

1. **Create bottle**: `cxbottle --bottle <B> --create --template win10_64` —
   CrossOver's CLI at `/Applications/CrossOver.app/Contents/SharedSupport/
   CrossOver/bin/`, works headlessly, no Dock presence.
2. **Install Steam**: download `SteamSetup.exe` (cdn.fastly.steamstatic.com),
   run `wine --bottle <B> --wait-children SteamSetup.exe /S` (NSIS silent).
   Installs the bootstrapper only (~3 MB of files).
3. **Fetch/refresh full client — no login needed**:
   `Steam.exe -forcesteamupdate -forcepackagedownload -exitsteam` (the
   lancache-prefill trick). Measured: full client downloaded and exited
   cleanly in **22 s**. This is also the "keep Steam up to date" mechanism —
   run it on app launch before starting the client proper.
4. **Run**: `wine --bottle <B> --no-wait Steam.exe -silent
   -cef-enable-debugging -devtools-port <n>`. Fresh-bottle client reaches CDP
   well under 90 s.
5. **Stop**: `Steam.exe -shutdown` → whole tree including the bottle's
   wineserver exits by itself (verified: zero processes left). Fallback for a
   hung client: `WINEPREFIX=<bottle path> wineserver -k` (note: `CX_BOTTLE`
   env is **not** honored by the wineserver wrapper — must use `WINEPREFIX`;
   verified both ways).
6. **Delete** (dev only): `cxbottle --bottle <B> --delete --force`.

Useful wine-wrapper flags discovered: `--wait-children`, `--wait-all`,
`--no-wait`, `--update-only` (bottle maintenance without running anything),
`--no-update`, `--cx-log`. `wine --bottle X cmd args` converts native paths
automatically (`--cx-app` does not — it resolves inside `drive_c` only).

**Dock reality check**: wine processes with windows (`steam.exe`,
`steamwebhelper.exe`) register as Dock-visible apps. In normal operation the
client is `-silent` and windowless so this only bites when Steam surfaces a
window (first-run login, EULA). Post-hoc `lsappinfo setinfo … 
ApplicationType=BackgroundOnly` sets the attribute but the Dock doesn't
re-evaluate — not a fix. Open question: macdrv registry switch or accepting
the icon during the rare "Steam needs attention" moments.

### Engine strategy: CrossOver first, OSS fallback (researched 2026-08-09)

**CrossOver (if installed) is the primary engine** — its CLI needs no GUI, and
CrossOver 25/26 carry Steam/CEF fixes that exist in no OSS binary: gcenx's
`wine-crossover` cask died 2026-04-16, frozen at crossover-sources 23.7.1
(Wine 8.0.1, can't boot the 2026 Steam client), and nobody builds newer CX
sources. The app detects CrossOver and recommends it as the happy path.

**The OSS path is real but needs one extra part.** Vanilla WineHQ 11.x
(official macOS builds at github.com/Gcenx/macOS_Wine_builds, current 11.15)
boots the 2026 Steam client but CEF renders black — until a **steamwebhelper
wrapper** injects CEF flags. Two working 2026 projects prove the recipe:
- vineport (MelonForAll/vineport): renames the real steamwebhelper.exe, re-execs
  appending `--no-sandbox --in-process-gpu --disable-gpu --disable-gpu-compositing`;
  downloads Wine Staging on demand (~190 MB, Whisky-style).
- notpop/steam-on-m1-wine: `--disable-gpu --single-process` variant + virtual
  desktop; login/store/D3D11 games verified on Tahoe.

Engine delivery imitates Whisky/Mythic (both documented from source): remote
version plist (`EngineUpdateStream.plist` pattern) + tarball extracted into
Application Support, per-bottle `Metadata.plist`, env assembly (incl. the
quirk: enabling msync must ALSO set `WINEESYNC=1` for D3DMetal), teardown via
`wineserver -k`. Graphics for games: **DXMT** (3Shain/dxmt, open source, what
CrossOver 26 itself bundles as 0.72) fetched from GitHub releases; GPTK 3.0
D3DMetal optionally via gcenx's cask — Apple's license allows non-commercial
redistribution only (fine for a free app, License.pdf must ride along).

### Client update pinning & tray suppression

- Emergency brake when a Steam update breaks under Wine: `steam.cfg` next to
  steam.exe with `BootStrapperInhibitAll=enable` (tradeoff: a pinned client
  eventually loses connectivity — use only while waiting for an engine fix).
- Wine maps Windows tray icons to real macOS menu-bar NSStatusItems (macdrv
  `systray.c`). Suppress all tray icons per-bottle with REG_DWORD
  `NoTrayItemsDisplay=1` under
  `HKCU\Software\Microsoft\Windows\CurrentVersion\Policies\Explorer` — the
  Explorer-policy key is the one that works; `ShowSystray` alone doesn't
  remove macdrv items and `Mac Driver` has no systray key. Since Sevoflurane's
  own menu-bar item replaces Steam's tray, suppress it — but remember `-silent`
  parks Steam "in the tray": with the tray hidden, every window-raise must go
  through our CDP/`steam://` path (which is the design anyway).

### MVP milestones

**M0 — spike: done.** Steam's own UI renders, library and all, from live client
data. The custom-library-grid plan it originally described is moot: hosting
Steam's UI supersedes it.

1. **M1 — in the app, not a browser.** Popups are adopted through
   `WKUIDelegate.createWebViewWith` sharing one configuration, each into a real
   `NSWindow` driven by `SteamClient.Window`. **Done**, except for two pieces
   that stay open: the Python bridge still has to become Swift
   (`WKScriptMessageHandler` + `URLSessionWebSocketTask`), and `BrowserView`
   still has to become a child `WKWebView`.
2. **M2 — chrome polish.** Window controls **done**; the mirrored macOS menu bar
   and the toolbar cluster remain, per *Native chrome* above.
3. **M3 — cockpit:** supervisor + watchdog + `steam://` handler; the client
   lifecycle currently living in `Spike/lifecycle.py`.
4. **M4 — provisioning:** bottle creation + Steam bootstrapper install from
   scratch on a clean machine; login flow polish.
5. **M5 — hygiene:** client-update survival soak test, EAC badge data (SteamDB
   anti-cheat lists), Sparkle updates, notarized DMG, `kagerou apps add sevoflurane`.

---

## Phase 2 — the lsteamclient route (the endgame)

The MVP still runs a whole Windows Steam client + hidden CEF in the bottle
(~hundreds of MB, plus Valve churn risk on the JS surface). The endgame inverts the
topology the way Proton does on Linux — and then the custom UI problem *disappears*
instead of being maintained:

**Native macOS Steam client is the UI and the backend. Games run in the bottle.
The bridge is a macOS port of Proton's `lsteamclient`.**

How Proton does it (validated in the research doc): `steam_api.dll` finds
"steamclient" via `HKCU\Software\Valve\Steam\ActiveProcess`; Proton points that
registry at **lsteamclient**, a generated ABI thunk (PE side ↔ unixlib side) that
dlopens the *native* `steamclient.so` inside the game's own process. The Steam wire
protocol is never translated — Valve's own native code does native IPC to the
native running client. A fake `steam.exe` satisfies process checks and fabricates
the Windows-visible Steam folders.

Every layer has a macOS analog: unixlibs dlopen host dylibs (winevulkan→MoltenVK is
this exact pattern, shipping in CrossOver today), and the macOS client ships
`steamclient.dylib` with the same versioned `CreateInterface` C++ ABI. Proton's
conversion layer is generated from SDK headers and largely platform-agnostic.
**natbro/kaon** has scoped this (vendors Proton 9.0's lsteamclient for a future
macOS port) but never built it. Nobody has.

### Milestones

1. **P0 — kaon replication:** make the *native* macOS Steam client launch a
   CrossOver-bottled Windows game at all: platform spoofing (`steam_dev.cfg`
   reporting Windows → client downloads Windows depots), per-game launch-option
   wrapper script into the bottle. Windows Steam client still present in the
   bottle at this stage purely to serve Steamworks.
2. **P1 — lsteamclient-mac PoC:** build lsteamclient with CrossOver's Wine
   toolchain as PE + Mach-O unixlib, dlopen `steamclient.dylib`, write the
   `ActiveProcess` registry redirect in the bottle, port the fake `steam.exe`.
   Acceptance: **SpaceWar (appid 480)** — the Steamworks SDK sample —
   initializes, gets ownership, and round-trips callbacks with *no Windows Steam
   client installed in the bottle*.
3. **P2 — real titles:** a DRM-wrapper (SteamStub) title; then overlay/Steam
   Input expectations documented; CEG titles flagged at-risk until proven.
4. **P3 — merge:** Sevoflurane's supervisor drops the in-bottle client entirely;
   the app becomes bottle provisioning + the bridge + launch integration, and the
   native Steam client everyone already has provides all UI.

### Known risks (phase 2)

- **Architecture matching:** the Wine process's Unix side must dlopen the dylib;
  x86_64 Wine under Rosetta needs an x86_64 slice of `steamclient.dylib`. The Mac
  client went native arm64 in mid-2025 — verify the x86_64 slice ships and works,
  or pin the x86_64 client build. Rosetta's removal (~macOS 28) is the sword over
  the whole x86-Windows-gaming-on-Mac stack, not just this.
- **Toolchain:** kaon reports winegcc/unixlib friction on macOS + protobuf
  struct-packing differences. Expect a build-system fight before any code runs.
- **Overlay/Steam Input:** the Mac client's injection into a Wine process is
  untested; may simply not work (acceptable — MVP parity).
- **CEG:** per-user executable generation needs active client cooperation; the
  Linux client gained Windows-CEG servicing in 2021, the Mac client's behavior is
  unknown. Flag titles, don't promise.

---

## Positioning & precedent

- Nobody ships this combination (research doc, prior-art table): Mythic has
  promised Steam since early 2025 and never landed it; Whisky is dead; Heroic
  removed its Steam-on-macOS path; OpenSteamClient proved custom-frontend-over-
  real-backend on Linux and died of vtable churn — which is the argument for the
  JS/CDP surface (stabler, community-tracked) in the MVP and for Valve's own
  native client in phase 2.
- ToS posture: same ground as Decky Loader / Millennium / SFP — driving one's own
  client through its own debugging interface, no redistribution, no DRM
  circumvention, emulators explicitly out of scope.

## Determinations from the 2026-08-09 experiments

| Fact | Value |
|---|---|
| CDP reachable from host | yes — `127.0.0.1:<port>`, wineserver sockets are host sockets |
| Debug port flag | `-cef-enable-debugging -devtools-port <n>` (per-launch, not persisted) |
| Privileged target | `SharedJSContext` (title-stable; Decky matches on it too) |
| Library model | `appStore` (431 apps), `collectionStore` — MobX, subscribable |
| Live call proven | `InstallFolder.GetInstallFolders()` → bottle library, 16 apps |
| Deeper seam | `WebUITransport.GetTransportInfo()` → protobuf-WebSocket ports + auth keys, also host-reachable |
| Retina root cause | webhelper renderer runs `--device-scale-factor=1` |
| `installed` flag | flips true the moment an install is *queued* — UI state must prefer download items / `progress` stages |
| DownloadOverview schema | no flat byte fields; `progress[]` array of pipeline stages (1 = allocation, 2 = network/compressed, 3 = written-to-disk = honest overall %), `update_state` is a string, speed in `update_network_bytes_per_second` |
| Artwork cache | modern client stores hashed filenames in `appcache/librarycache/<appid>/`; legacy `library_600x900.jpg` only for entries cached by older clients — fall back to `shared.steamstatic.com/store_item_assets/steam/apps/<appid>/library_600x900.jpg` |
| Test throttle | `SteamClient.Console.ExecCommand('set_download_throttle <kbps>')` (0 = off) — the only way to make installs slow enough to observe on this connection |
