import AppKit
import Observation
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
    weak var menuMirror: SteamMenuMirror?

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

    @ObservationIgnored private var context: SteamWindow?
    @ObservationIgnored private var contextWindow: NSWindow?
    @ObservationIgnored private var popups: [ObjectIdentifier: SteamWindow] = [:]
    @ObservationIgnored private var coordinator: SteamWebCoordinator?

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
            contentRect: NSRect(
                x: -20_000,
                y: -20_000,
                width: 1280,
                height: 800,
            ),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        let container = NSView(frame: webView.frame)
        container.addSubview(webView)
        window.contentView = container
        window.orderBack(nil)
        contextWindow = window

        status = "starting Steam"
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
    /// `-silent` client does until its tray item is clicked.
    func openLibrary() {
        navigate(.library)
    }

    /// Sends the desktop window to one of Steam's own routes.
    ///
    /// `SteamClient.URL.ExecuteSteamURL` would be the obvious lever, but it
    /// runs inside the *bottle's* client and navigates the window that client
    /// owns. Steam's navigator lives in this page, next to the window it
    /// actually drives.
    func navigate(_ route: SteamRoute) {
        context?.webView.evaluateJavaScript("""
        (function () {
          var window_ = window.SteamUIStore && SteamUIStore.WindowStore
            && SteamUIStore.WindowStore.MainWindowInstance;
          var nav = window_ && window_.Navigator;
          if (!nav || typeof nav.\(route.navigatorFunction) !== "function") return false;
          nav.\(route.navigatorFunction)();
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
        let literal = Self.jsLiteral(url.absoluteString)
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
    fileprivate func adoptPopup(
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

    fileprivate func window(for webView: WKWebView) -> SteamWindow? {
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
        EventLog.shared.log(.window, "desktop window adopted — Steam is ready")
        // Steam draws a Windows title bar because under CEF it owns a
        // borderless OS window. Hosted here its buttons duplicate the traffic
        // lights and its strip has nowhere for them to sit.
        window.webView.evaluateJavaScript(SteamDesktopChrome.script)
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

    fileprivate func setStatus(_ value: String) {
        status = value
    }

    private static func jsLiteral(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// A web view whose first click counts.
///
/// A menu panel opens without key status, so every initial click in it is a
/// "first mouse". WKWebView's default answer spends that click on making the
/// panel key — Steam's menus then need one click to highlight and a second to
/// activate. In a panel the click always belongs to the page.
private final class SteamWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is NSPanel || super.acceptsFirstMouse(for: event)
    }
}

// MARK: - WebKit plumbing

/// The WebKit delegates, kept off ``SteamWebHost`` so the observable state is
/// not also an `NSObject` full of protocol conformances.
@MainActor
private final class SteamWebCoordinator: NSObject {
    static let handlerName = "sevoWindow"

    private weak var host: SteamWebHost?

    init(host: SteamWebHost) {
        self.host = host
    }
}

extension SteamWebCoordinator: WKUIDelegate {
    func webView(
        _: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures,
    ) -> WKWebView? {
        // Steam's popup manager always opens about:blank and writes into it;
        // a popup opened straight onto http(s) is an external link, and those
        // belong in the user's browser, not in an orphan app window.
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return nil
        }
        return host?.adoptPopup(configuration: configuration, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.window(for: webView)?.detach()
    }

    /// WebKit's source of truth for `window.screenX/screenY/outer*` — without
    /// this (private) delegate method it answers a zero rect, which Steam's
    /// menu placement reads as "the window fills nothing at the bottom of the
    /// screen" and flips every flyout upward. The rect is the AppKit frame;
    /// WebKit flips it to CSS coordinates itself (`convertToUserSpace`).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func _webView(
        _ webView: WKWebView,
        getWindowFrameWithCompletionHandler completionHandler: @escaping (CGRect) -> Void,
    ) {
        completionHandler(host?.window(for: webView)?.appKitFrame ?? .zero)
    }
}

extension SteamWebCoordinator: WKNavigationDelegate {
    /// Steam's menus navigate to `steam://open/*` and expect the host to
    /// intercept — CEF does; WKWebView would hand the unknown scheme to
    /// LaunchServices, launching the real Mac Steam app. Everything that is
    /// not part of the UI's own page traffic is cancelled, and `steam:` URLs
    /// are routed back into the client.
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
    ) async
        -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url,
              let scheme = url.scheme?.lowercased() else { return .allow }
        switch scheme {
        case "http", "https", "about", "blob", "data":
            return .allow
        case "steam":
            host?.executeSteamURL(url)
            return .cancel
        default:
            return .cancel
        }
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        guard host?.window(for: webView)?.role == .context else { return }
        host?.setStatus("Steam UI booted — waiting for its window")
    }

    func webView(_: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        host?.setStatus("load failed: \(error.localizedDescription)")
        EventLog.shared.log(.page, "page load failed: \(error.localizedDescription)")
    }

    func webView(
        _: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error,
    ) {
        host?.setStatus("bridge unreachable: \(error.localizedDescription)")
        EventLog.shared.log(.bridge, "bridge unreachable: \(error.localizedDescription)")
    }
}

extension SteamWebCoordinator: WKScriptMessageHandlerWithReply {
    /// Every `SteamClient.Window` call arrives here. `message.webView` is the
    /// window the call is about, which is why the shim posts through the
    /// popup's own handler rather than the opener's: it identifies the target
    /// without a handshake.
    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) async -> (Any?, String?) {
        guard let body = message.body as? [String: Any],
              let function = body["fn"] as? String,
              let webView = message.webView,
              let window = host?.window(for: webView) else {
            return (nil, nil)
        }
        return (window.perform(function, body["args"] as? [Any] ?? []), nil)
    }
}
