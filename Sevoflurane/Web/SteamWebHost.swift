import AppKit
import Observation
import os
import WebKit

/// Owns the web side of the app.
///
/// Steam's UI is one JavaScript context that renders its visible windows into
/// popups it opens itself. Reproducing that shape is what lets the app ship no
/// UI of its own: a hidden web view runs the context, and every popup it opens
/// is adopted into a real `NSWindow`.
///
/// The popups must be built from the *same* `WKWebViewConfiguration` as the
/// context. That keeps them in one web content process, which is what lets the
/// opener script them across documents — the thing CEF gives Steam for free and
/// the whole architecture depends on.
@MainActor
@Observable
final class SteamWebHost {
    /// Steam's own `steamui` bundle, served with the `SteamClient` shim
    /// injected and proxied to the client running in the bottle.
    static let uiURL = URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/")!

    private(set) var status = "idle"
    /// The desktop window, once Steam has opened it.
    private(set) var desktop: SteamWindow?

    /// The menu-bar mirror, refreshed when the desktop window comes up.
    @ObservationIgnored weak var menuMirror: SteamMenuMirror?

    /// The most recently played installed games, for the menu-bar extra —
    /// the same list Steam's own tray menu leads with.
    private(set) var recentGames: [RecentGame] = []

    struct RecentGame: Identifiable, Decodable, Equatable {
        let id: Int
        let name: String
        /// Capsule art, served by the bridge (local cache, CDN fallback).
        var artURL: URL {
            URL(string: "http://127.0.0.1:\(BridgePorts.art)/art/\(id).jpg")!
        }
    }

    func refreshRecentGames() {
        Task(name: "Refresh recent games") {
            let script = """
            JSON.stringify((window.appStore ? appStore.allApps : [])
              .filter(function (a) { return a.installed && a.app_type === 1; })
              .sort(function (x, y) {
                return (y.rt_last_time_played || 0) - (x.rt_last_time_played || 0);
              })
              .slice(0, 5)
              .map(function (a) { return { id: a.appid, name: a.display_name }; }))
            """
            guard let raw = await evaluateInContext(script),
                  let data = raw.data(using: .utf8),
                  let games = try? JSONDecoder().decode([RecentGame].self, from: data),
                  games != recentGames else { return }
            recentGames = games
        }
    }

    /// Launches a game exactly as Steam's tray menu does.
    func launchGame(_ game: RecentGame) {
        context?.webView.evaluateJavaScript(
            "SteamClient.Apps.RunGame(String(\(game.id)), '', -1, 100)",
        )
    }

    // MARK: - Launch status

    /// A launch in flight, told by the client's own game-action events — the
    /// signal the menu bar's spinner used to guess at with a timer.
    struct GameLaunch: Equatable {
        let appID: Int
        var detail: String
    }

    private(set) var activeLaunch: GameLaunch?
    @ObservationIgnored private var launchClear: Task<Void, Never>?

    /// One `__gameAction` event from the context page's registrations
    /// (``gameActionScript``). The trail also lands in the log, so a slow
    /// launch explains itself after the fact.
    func noteGameAction(phase: String, appID: String, task: String) {
        switch phase {
        case "start":
            EventLog.shared.log(.client, "launch \(appID): \(task.isEmpty ? "begun" : task)")
            setLaunch(GameLaunch(appID: Int(appID) ?? 0, detail: "Preparing…"), clearAfter: 180)
        case "task":
            guard !task.isEmpty, task != "None" else { return }
            EventLog.shared.log(.client, "launch \(appID): \(task)")
            let id = Int(appID) ?? activeLaunch?.appID ?? 0
            setLaunch(GameLaunch(appID: id, detail: Self.launchTaskText(task)), clearAfter: 180)
        case "end":
            // The launch flow is done but the engine still has to put up its
            // first window; GameLaunchWatch ends the story when it does.
            EventLog.shared.log(.client, "launch flow finished — waiting for the game window")
            if var launch = activeLaunch {
                launch.detail = "Waiting for the game window…"
                setLaunch(launch, clearAfter: 20)
            }
        default:
            break
        }
    }

    /// The game's first window is up (``GameLaunchWatch``) — story over.
    func gameWindowDidAppear() {
        guard activeLaunch != nil else { return }
        launchClear?.cancel()
        activeLaunch = nil
    }

    private func setLaunch(_ launch: GameLaunch, clearAfter seconds: Int) {
        activeLaunch = launch
        launchClear?.cancel()
        launchClear = Task(name: "Launch status expiry") { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activeLaunch = nil
        }
    }

    /// Steam's launch-pipeline task names, in user words. `Show*` tasks are
    /// the launch dialogs (EULA, launch options, playtime controls) — those
    /// wait on the user, not the machine. Unknown names fall back to the raw
    /// identifier spaced out: honest beats silent.
    private static func launchTaskText(_ task: String) -> String {
        switch task {
        case "ProcessingInstallScript": "Running the install script…"
        case "VerifyingFiles": "Verifying files…"
        case "SynchronizingCloud": "Syncing cloud saves…"
        case "SynchronizingControllerConfig": "Syncing controller config…"
        case "ProcessingShaderCache": "Processing shaders…"
        case "DownloadingWorkshop": "Updating Workshop items…"
        case "KickingOtherSession": "Signing out another session…"
        case "CreatingProcess", "Completed": "Starting the game…"
        case "WaitingGameWindow": "Waiting for the game window…"
        default:
            task.hasPrefix("Show")
                ? "Waiting for you in the Steam window…"
                : task.reduce(into: "") { result, character in
                    if character.isUppercase, !result.isEmpty { result.append(" ") }
                    result.append(result.isEmpty ? character : Character(character.lowercased()))
                } + "…"
        }
    }

    /// Subscribes the context page to the client's game-action events; they
    /// come back through the popup message handler as `__gameAction`.
    /// Idempotent per page session, and a reload re-registers because the
    /// desktop window is re-adopted.
    private static let gameActionScript = """
    (function () {
      if (window.__sevoGameActions) return "already registered";
      if (!window.SteamClient || !SteamClient.Apps
          || !SteamClient.Apps.RegisterForGameActionStart) return "unavailable";
      window.__sevoGameActions = true;
      var post = function (args) {
        try {
          window.webkit.messageHandlers.sevoWindow
            .postMessage({ fn: "__gameAction", args: args });
        } catch (e) {}
      };
      SteamClient.Apps.RegisterForGameActionStart(function (id, appid, action) {
        post(["start", String(appid), String(action || "")]);
      });
      SteamClient.Apps.RegisterForGameActionTaskChange(function (id, appid, task) {
        post(["task", String(appid), String(task || "")]);
      });
      SteamClient.Apps.RegisterForGameActionEnd(function () {
        post(["end", "", ""]);
      });
      return "registered";
    })()
    """

    @ObservationIgnored private var context: SteamWindow?
    @ObservationIgnored private var contextWindow: NSWindow?
    @ObservationIgnored private var contextMoveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var popups: [ObjectIdentifier: SteamWindow] = [:]
    @ObservationIgnored private var coordinator: SteamWebCoordinator?

    private static let contextParkOrigin = CGPoint(x: -20_000, y: -20_000)

    /// Every window the host owns, for `sevo` diagnostics
    /// (control endpoint `GET /windows`).
    func windowInventory() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        if let contextWindow {
            rows.append([
                "name": "SharedJSContext",
                "role": "context",
                "frame": NSStringFromRect(contextWindow.frame),
                "visible": contextWindow.isVisible,
            ])
        }
        for popup in popups.values {
            rows.append([
                "name": popup.name,
                "role": String(describing: popup.role),
                "frame": NSStringFromRect(popup.appKitFrame),
                "visible": popup.isWindowVisible,
            ])
        }
        return rows
    }

    // MARK: - Boot

    /// Starts Steam's UI at launch rather than on first window open, mirroring
    /// the client itself: by the time the user asks for a window, the UI is
    /// already running and the window can be handed over immediately.
    func bootstrap() {
        guard context == nil else { return }

        let coordinator = SteamWebCoordinator(host: self)
        self.coordinator = coordinator

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.addScriptMessageHandler(
            coordinator, contentWorld: .page, name: SteamWebCoordinator.handlerName,
        )

        let webView = makeWebView(configuration: configuration)
        // The name deliberately mirrors the title of the real client's context
        // page this window stands in for; it travels back to Steam through
        // GetWindowRestoreDetails.
        let page = SteamWindow(
            webView: webView,
            role: .context,
            name: "SharedJSContext",
            size: CGSize(width: 1280, height: 800),
            origin: nil,
            host: self,
        )
        context = page

        // The context renders nothing, but WebKit only schedules a web view
        // that lives in a window, so it is parked off-screen.
        let window = NSWindow(
            contentRect: NSRect(origin: Self.contextParkOrigin, size: CGSize(width: 1280, height: 800)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        // A display-mode change (a game going fullscreen) makes the window
        // server relocate off-screen windows onto a live screen, where this
        // one showed as a bare white 1280×800 rectangle. Invisible and
        // click-through, so even a brief surfacing shows nothing — and the
        // move observer below puts it straight back.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let container = NSView(frame: webView.frame)
        container.addSubview(webView)
        window.contentView = container
        window.orderBack(nil)
        contextWindow = window
        contextMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main,
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.frame.origin != Self.contextParkOrigin else { return }
                EventLog.shared.log(
                    .window,
                    "context window moved to \(window.frame.origin) (display change) — re-parking",
                )
                window.setFrameOrigin(Self.contextParkOrigin)
            }
        }

        status = "starting Steam"
        PerfProbe.poi.emitEvent("PageBoot")
        EventLog.shared.log(.page, "booting the Steam UI from \(Self.uiURL.absoluteString)")
        webView.load(URLRequest(url: Self.uiURL))
    }

    func reload() {
        EventLog.shared.log(.page, "reloading the UI page (\(popups.count) popups detached)")
        for popup in popups.values {
            popup.detach()
        }
        popups.removeAll()
        desktop = nil
        status = "reloading"
        context?.webView.load(URLRequest(url: Self.uiURL))
    }

    /// Brings Steam's window up, opening the library if the UI has not put a
    /// window on screen yet.
    func showSteam() {
        if let desktop {
            desktop.show(activating: true)
        } else {
            openLibrary()
        }
    }

    /// The context boots its window on no route at all, the same way a
    /// `-silent` client does until its tray item is clicked. The route runs
    /// through Steam's own navigator in this page — `ExecuteSteamURL` would
    /// navigate the window the *bottle's* client owns instead.
    func openLibrary() {
        context?.webView.evaluateJavaScript("""
        (function () {
          var window_ = window.SteamUIStore && SteamUIStore.WindowStore
            && SteamUIStore.WindowStore.MainWindowInstance;
          var nav = window_ && window_.Navigator;
          if (!nav || typeof nav.Home !== "function") return false;
          nav.Home();
          return true;
        })()
        """)
    }

    /// Evaluates a script in the hidden context page and returns its result,
    /// which the script must produce as a string — structured results cross
    /// as JSON. The completion-handler API is wrapped by hand because the
    /// async overlay traps when the script's value is `null`; here a stray
    /// null answers `nil` instead of crashing.
    func evaluateInContext(_ script: String) async -> String? {
        guard let webView = context?.webView else { return nil }
        return await withCheckedContinuation { continuation in
            webView.evaluateJavaScript(script) { value, _ in
                continuation.resume(returning: value as? String)
            }
        }
    }

    /// Runs a `steam://` URL against the handlers this page registered — the
    /// dispatch CEF's scheme interception ends in, without the client round
    /// trip. `ExecuteSteamURL` broadcasts to every UI including the bottle
    /// client's own, which then raises a real (visible) Wine window for
    /// dialogs like About; the local path keeps it in this process. The round
    /// trip remains as fallback for URLs only the client resolves.
    func executeSteamURL(_ url: URL) {
        let literal = JSLiteral.string(url.absoluteString)
        Task(name: "Run \(url.absoluteString)") {
            let handled = await evaluateInContext(
                "String(window.__sevoRunSteamURL ? __sevoRunSteamURL(\(literal)) : 0)",
            )
            if handled == nil || handled == "0" {
                _ = await evaluateInContext(
                    "SteamClient.URL.ExecuteSteamURL(\(literal)), \"sent\"",
                )
            }
        }
    }

    // MARK: - Popup adoption

    private func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = SteamWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: configuration,
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        // `developerExtrasEnabled` alone only adds the context-menu item; Safari
        // cannot attach to the page without this, and Steam's DOM is the only
        // place its layout can be measured.
        webView.isInspectable = true
        // Steam's own background paints the whole page; letting WebKit paint an
        // opaque base under it flashes white on every popup and blocks the
        // transparency the menus need.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        // With occlusion detection on, WebKit marks pages hidden whenever the
        // occlusion service says so — which it does for the off-screen context
        // window (all of Steam's JS, timer-throttled) and for pop-up-level
        // menu panels (whose pages then never run their fade-ins, and Steam's
        // menu re-measure loop flickers the window). Visibility should follow
        // plain window visibility here.
        if webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:"))) {
            webView.setValue(false, forKey: "windowOcclusionDetectionEnabled")
        }
        return webView
    }

    /// Steam's popup manager calls `window.open` and then writes the popup's
    /// document itself. WebKit hands us the chance to supply the web view; the
    /// window around it waits until the shim says which popup this is, because
    /// the name is the only thing that tells a context menu from the desktop.
    func adoptPopup(
        configuration: WKWebViewConfiguration,
        features: WKWindowFeatures,
    ) -> WKWebView {
        let size = CGSize(
            width: plausible(features.width) ?? 640,
            height: plausible(features.height) ?? 480,
        )
        let origin: CGPoint? = if let x = plausible(features.x),
                                  let y = plausible(features.y) {
            CGPoint(x: x, y: y)
        } else {
            nil
        }
        let webView = makeWebView(configuration: configuration)
        let popup = SteamWindow(
            webView: webView,
            role: .auxiliary,
            name: "",
            size: size,
            origin: origin,
            host: self,
        )
        popups[ObjectIdentifier(webView)] = popup

        // Every popup Steam opens is adopted a moment later over the shim. A
        // window opened by anything else still needs a frame to live in.
        Task(name: "Adopt orphan popup") { [weak popup] in
            try? await Task.sleep(for: .milliseconds(400))
            popup?.adopt(name: "", parameters: "")
        }
        return webView
    }

    /// A window feature WebKit actually measured.
    ///
    /// Steam's popup manager leaves `left` and `top` out of the features string
    /// for any window it means to place itself, and WebKit fills the gap with
    /// `INT_MIN`. Handed to AppKit unexamined that becomes a window two billion
    /// points off-screen, whose layer geometry takes the process down with it.
    private func plausible(_ value: NSNumber?) -> CGFloat? {
        guard let value else { return nil }
        let number = value.doubleValue
        guard number.isFinite, abs(number) < 100_000 else { return nil }
        return CGFloat(number)
    }

    func window(for webView: WKWebView) -> SteamWindow? {
        if webView === context?.webView { return context }
        return popups[ObjectIdentifier(webView)]
    }

    /// The top-left of a window Steam named, in the coordinates it measures in.
    /// Menus are placed relative to whichever window opened them.
    func steamOrigin(ofWindowNamed name: String) -> CGPoint? {
        popups.values.first { $0.name == name }?.steamOrigin
    }

    func windowDidAdopt(_ window: SteamWindow) {
        // Every adoption is a chance the root menus now exist — they are
        // created after the desktop window, so anchoring on the desktop alone
        // reads an empty strip. Re-reading an unchanged strip is a no-op.
        menuMirror?.refresh()
        guard window.role == .desktop else { return }
        desktop = window
        status = "Steam is ready"
        PerfProbe.poi.emitEvent("DesktopAdopted")
        EventLog.shared.log(.window, "desktop window adopted — Steam is ready")
        // Steam draws a Windows title bar because under CEF it owns a
        // borderless OS window. Hosted here its buttons duplicate the traffic
        // lights and its strip has nowhere for them to sit.
        window.webView.evaluateJavaScript(SteamDesktopChrome.script)
        Task(name: "Register game-action events") {
            let result = await evaluateInContext(Self.gameActionScript)
            EventLog.shared.log(.client, "game-action events: \(result ?? "no answer")")
        }
        refreshRecentGames()
        // A client started with -silent opens its window on no route at all.
        // Steam's tray item resolves that by asking for the library, and so
        // does the first thing the user sees here.
        Task(name: "Open library") {
            try? await Task.sleep(for: .seconds(1))
            openLibrary()
        }
    }

    func windowDidHide(_ window: SteamWindow) {
        guard window === desktop else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    func windowDidClose(_ window: SteamWindow) {
        popups.removeValue(forKey: ObjectIdentifier(window.webView))
        guard window === desktop else { return }
        desktop = nil
        status = "Steam window closed"
        EventLog.shared.log(.window, "desktop window closed")
        NSApp.setActivationPolicy(.accessory)
    }

    func setStatus(_ value: String) {
        status = value
    }
}
