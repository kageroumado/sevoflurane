import AppKit
import os
import WebKit

/// One embedded web page (store, community, profile) living as a native child
/// web view over a Steam window's page — the WKWebView stand-in for CEF's
/// BrowserView. Its cookies persist in the default website data store, so a
/// web login in the store survives app restarts.
@MainActor
final class BrowserViewChild: NSObject {
    struct Status: Encodable {
        let id: Int
        let visible: Bool
        let url: String?
        let isLoading: Bool
        let frame: String
    }

    let webView: WKWebView

    /// The native readiness signal for a Steam BrowserView: it is on screen,
    /// has a concrete URL, and WebKit has no outstanding top-level load.
    var isSettledAndVisible: Bool {
        !webView.isHidden && webView.url != nil && !webView.isLoading
    }

    var loadedHost: String? {
        webView.url?.host?.lowercased()
    }

    var status: Status {
        Status(
            id: id,
            visible: !webView.isHidden,
            url: webView.url?.absoluteString,
            isLoading: webView.isLoading,
            frame: NSStringFromRect(webView.frame),
        )
    }

    private let id: Int
    /// The hosting window's page, where the shim's event sink lives.
    private let hostPage: WKWebView
    private weak var host: SteamWebHost?
    private weak var container: NSView?

    init(id: Int, container: NSView, hostPage: WKWebView, host: SteamWebHost) {
        self.id = id
        self.hostPage = hostPage
        self.host = host
        self.container = container

        let configuration = WKWebViewConfiguration()
        // Steam's web properties feature-detect the client from this token
        // (install buttons become steam:// links, which route back natively).
        configuration.applicationNameForUserAgent = "Valve Steam Client"
        var scripts: [WKUserScript] = []
        if let mask = StreamerMask.script(for: .current) {
            scripts.append(WKUserScript(
                source: mask, injectionTime: .atDocumentEnd, forMainFrameOnly: false,
            ))
        }
        // The Mac compatibility strip on store game pages. It asks for its
        // record on every page, so the Settings switch reaches pages loaded
        // after it changed.
        scripts.append(WKUserScript(
            source: SteamCompatBadge.storeScript, injectionTime: .atDocumentEnd, forMainFrameOnly: true,
        ))
        baseScripts = scripts
        for script in scripts {
            configuration.userContentController.addUserScript(script)
        }
        if let stylesheet = host.webPageStylesheet {
            configuration.userContentController.addUserScript(Self.userStyleScript(stylesheet))
        }
        configuration.userContentController.addScriptMessageHandler(
            StoreCompatHandler(), contentWorld: .page, name: SteamCompatBadge.storeHandler,
        )
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isHidden = true
        webView.allowsBackForwardNavigationGestures = true
        webView.isInspectable = true
        // Steam's tracking placeholders are empty pages; an opaque white flash
        // under every internal route is WebKit's default without this.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
        // Steam re-sends bounds on layout changes; between those, a flexible
        // bottom margin keeps the view pinned to its top-left in AppKit's
        // flipped terms.
        webView.autoresizingMask = [.minYMargin]
        container.addSubview(webView)
        // Same-document navigations (the store and community are pushState
        // SPAs) never reach the navigation delegate; the URL and title
        // observations are what keeps Steam's history model and title bar in
        // sync for those.
        observations = [
            webView.observe(\.url) { [weak self] _, _ in
                onMainThread { self?.fireHistoryChanged() }
            },
            webView.observe(\.title) { [weak self] view, _ in
                onMainThread {
                    guard let self, let title = view.title else { return }
                    self.fire("set-title", "[\(JSLiteral.string(title))]")
                }
            },
        ]
    }

    private var observations: [NSKeyValueObservation] = []

    /// The user scripts every page gets; the custom style's is added and
    /// removed beside them.
    private let baseScripts: [WKUserScript]

    /// Puts `stylesheet` on the open page and every page loaded after it, or
    /// takes the custom style off them for `nil`.
    func setUserStylesheet(_ stylesheet: String?) {
        let controller = webView.configuration.userContentController
        controller.removeAllUserScripts()
        for script in baseScripts {
            controller.addUserScript(script)
        }
        if let stylesheet {
            controller.addUserScript(Self.userStyleScript(stylesheet))
        }
        webView.evaluateJavaScript(stylesheet.map { SteamUserCSS.script(css: $0) } ?? SteamUserCSS.removalScript)
    }

    /// At document start, so the style is in place before the first paint.
    private static func userStyleScript(_ stylesheet: String) -> WKUserScript {
        WKUserScript(
            source: SteamUserCSS.script(css: stylesheet), injectionTime: .atDocumentStart, forMainFrameOnly: true,
        )
    }

    /// The open `BrowserViewLoad` interval: provisional start to finish or
    /// failure of the top-level load. A navigation that replaces one in
    /// flight closes the first as `superseded`.
    private var loadInterval: OSSignpostIntervalState?

    private func beginLoadInterval(host: String) {
        endLoadInterval(outcome: "superseded")
        loadInterval = PerfProbe.bridge.beginInterval(
            "BrowserViewLoad", id: PerfProbe.bridge.makeSignpostID(),
            "view=\(self.id, privacy: .public),host=\(host, privacy: .public)",
        )
    }

    private func endLoadInterval(outcome: String) {
        guard let loadInterval else { return }
        self.loadInterval = nil
        PerfProbe.bridge.endInterval(
            "BrowserViewLoad", loadInterval,
            "view=\(self.id, privacy: .public),outcome=\(outcome, privacy: .public)",
        )
    }

    /// Runs `script` when this view shows a Steam store page.
    func evaluateOnStore(_ script: String) {
        guard loadedHost == "store.steampowered.com" else { return }
        webView.evaluateJavaScript(script)
    }

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Bounds arrive in CSS pixels from the top-left of the hosting page.
    func setBounds(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        guard let container else { return }
        webView.frame = CGRect(
            x: x,
            y: container.bounds.height - y - height,
            width: width,
            height: height,
        )
    }

    func setVisible(_ visible: Bool) {
        webView.isHidden = !visible
    }

    func postMessage(type: String, dataJSON: String) {
        webView.evaluateJavaScript(
            "window.postMessage({type: \(JSLiteral.string(type)), data: \(dataJSON.isEmpty ? "null" : dataJSON)}, '*')",
        )
    }

    func destroy() {
        observations = []
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        webView.removeFromSuperview()
    }

    /// Delivers an event to the shim's emitter for this view in the host page.
    private func fire(_ event: String, _ argsJSON: String) {
        hostPage.evaluateJavaScript(
            "window.__sevoBV && __sevoBV[\(id)] && __sevoBV[\(id)](\(JSLiteral.string(event)), \(argsJSON))",
        )
    }

    /// Steam's browser manager mirrors the browser's *whole* history model —
    /// `history-changed` must carry `{entries: [{url, key}…], index}` or its
    /// `LoadURL` throws before ever reaching the browser and every web
    /// navigation silently dies on the previous page.
    func fireHistoryChanged() {
        let list = webView.backForwardList
        var entries = list.backList.map(Self.historyEntry)
        if let current = list.currentItem { entries.append(Self.historyEntry(current)) }
        var index = entries.count - 1
        if index < 0 {
            entries = [["url": "about:blank", "key": "0"]]
            index = 0
        }
        entries.append(contentsOf: list.forwardList.map(Self.historyEntry))
        let model: [String: Any] = ["entries": entries, "index": index]
        if let data = try? JSONSerialization.data(withJSONObject: [model]),
           let json = String(data: data, encoding: .utf8) {
            fire("history-changed", json)
        }
        fire("can-go-back-forward-changed", "[\(webView.canGoBack), \(webView.canGoForward)]")
    }

    /// A history entry's key identifies it across diffs (push/pop/replace
    /// detection, client backstack jumps); the item's identity is the one
    /// thing stable for its lifetime.
    private static func historyEntry(_ item: WKBackForwardListItem) -> [String: String] {
        [
            "url": item.url.absoluteString,
            "key": String(UInt(bitPattern: ObjectIdentifier(item).hashValue), radix: 36),
        ]
    }
}

extension BrowserViewChild: WKNavigationDelegate {
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
    ) async
        -> WKNavigationActionPolicy {
        steamNavigationPolicy(for: navigationAction.request.url, host: host)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        let url = JSLiteral.string(webView.url?.absoluteString ?? "")
        beginLoadInterval(host: webView.url?.host ?? "")
        fire("start-request", "[\(url)]")
        fire("start-loading", "[\(url)]")
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        endLoadInterval(outcome: "finished")
        fire(
            "finished-request",
            "[\(JSLiteral.string(webView.url?.absoluteString ?? "")), "
                + "\(JSLiteral.string(webView.title ?? ""))]",
        )
        fireHistoryChanged()
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        loadError(webView, error)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation _: WKNavigation!,
        withError error: any Error,
    ) {
        loadError(webView, error)
    }

    private func loadError(_ webView: WKWebView, _ error: any Error) {
        endLoadInterval(outcome: "failed code=\((error as NSError).code)")
        EventLog.shared.log(.page, "browser view load failed: \(error.localizedDescription)")
        fire(
            "load-error",
            "[\((error as NSError).code), "
                + "\(JSLiteral.string(webView.url?.absoluteString ?? "")), "
                + "\(JSLiteral.string(error.localizedDescription))]",
        )
        fireHistoryChanged()
    }
}

extension BrowserViewChild: WKUIDelegate {
    /// `target=_blank` in embedded web content is an external link; it belongs
    /// in the user's browser.
    func webView(
        _: WKWebView,
        createWebViewWith _: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures,
    ) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

/// Answers the store page's Mac compatibility strip: the record for a game
/// (``GameCompatService``), the same one the library page draws, or
/// `{"off": true}` while Settings has the strip off. A message carrying
/// `open` is a source link, opened in the default browser; one carrying
/// `playMac` starts the game's macOS build in Steam for Mac.
private final class StoreCompatHandler: NSObject, WKScriptMessageHandlerWithReply {
    func userContentController(
        _: WKUserContentController, didReceive message: WKScriptMessage,
    ) async -> (Any?, String?) {
        guard message.frameInfo.isMainFrame,
              message.frameInfo.securityOrigin.host == "store.steampowered.com",
              let body = message.body as? [String: Any] else { return (nil, "refused") }
        if let link = body["open"] as? String {
            if let url = URL(string: link), url.scheme == "https" { NSWorkspace.shared.open(url) }
            return (nil, nil)
        }
        if let appID = (body["playMac"] as? NSNumber)?.intValue, appID > 0 {
            MacBuildHandoff.playMacBuild(appID: appID)
            return (nil, nil)
        }
        guard Preferences.compatibilityStrip else { return (#"{"off":true}"#, nil) }
        guard let appID = (body["appid"] as? NSNumber)?.intValue, appID > 0 else { return (nil, "no appid") }
        let name = body["name"] as? String ?? ""
        let data = await GameCompatService.shared.recordJSON(appID: appID, name: name, deckCategory: nil)
        return (String(decoding: data, as: UTF8.self), nil)
    }
}
