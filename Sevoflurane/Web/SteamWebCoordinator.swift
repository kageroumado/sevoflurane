import AppKit
import WebKit

/// A web view whose first click in a panel reaches the page; WKWebView's
/// default spends it on making the panel key, so menus needed two clicks.
final class SteamWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is NSPanel || super.acceptsFirstMouse(for: event)
    }
}

// MARK: - WebKit plumbing

/// The WebKit delegates for ``SteamWebHost``.
@MainActor
final class SteamWebCoordinator: NSObject {
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
        // Steam's popup manager always opens about:blank; a popup opened
        // onto http(s) is an external link for the user's browser.
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
            return nil
        }
        return host?.adoptPopup(configuration: configuration, features: windowFeatures)
    }

    func webViewDidClose(_ webView: WKWebView) {
        host?.window(for: webView)?.detach(reason: .steamClosedIt)
    }

    /// A file input in Steam's UI (Set Custom Artwork, a non-Steam game's
    /// icon), answered by the Mac's open panel.
    ///
    /// Must be the async form: the completion-handler form takes a
    /// `@MainActor` block, and a method declared with a plain closure binds
    /// to no selector, so WebKit finds no delegate.
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame _: WKFrameInfo,
    ) async -> [URL]? {
        await WebFilePanel.choose(parameters, for: webView)
    }

    /// WebKit's source for `window.screenX/screenY/outer*`. Without this
    /// private method it answers a zero rect, and Steam flips every flyout
    /// upward. The rect is the AppKit frame; WebKit flips it to CSS
    /// coordinates (`convertToUserSpace`).
    @objc(_webView:getWindowFrameWithCompletionHandler:)
    func _webView(
        _ webView: WKWebView,
        getWindowFrameWithCompletionHandler completionHandler: @escaping (CGRect) -> Void,
    ) {
        completionHandler(host?.window(for: webView)?.appKitFrame ?? .zero)
    }
}

/// The navigation policy of every web view hosting Steam content: page
/// traffic passes, `steam://` routes back into the client, and any other
/// scheme is cancelled, since WKWebView would hand it to LaunchServices and
/// launch the real Mac Steam app.
@MainActor
func steamNavigationPolicy(for url: URL?, host: SteamWebHost?) -> WKNavigationActionPolicy {
    guard let url, let scheme = url.scheme?.lowercased() else { return .allow }
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

extension SteamWebCoordinator: WKNavigationDelegate {
    func webView(
        _: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
    ) async
        -> WKNavigationActionPolicy {
        steamNavigationPolicy(for: navigationAction.request.url, host: host)
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

    /// The page's process died, leaving the view blank; from outside this
    /// looks like a hung Steam UI.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        host?.webProcessDidTerminate(for: webView)
    }
}

extension SteamWebCoordinator: WKScriptMessageHandlerWithReply {
    /// Every `SteamClient.Window` call arrives here. The shim posts through
    /// the popup's own handler, so `message.webView` is the target window.
    func userContentController(
        _: WKUserContentController,
        didReceive message: WKScriptMessage,
    ) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard Self.admitsMessage(
            isMainFrame: message.frameInfo.isMainFrame,
            origin: (origin.protocol, origin.host, origin.port),
        ) else {
            return (nil, nil)
        }
        guard let body = message.body as? [String: Any],
              let function = body["fn"] as? String,
              let webView = message.webView,
              let window = host?.window(for: webView) else {
            return (nil, nil)
        }
        let args = body["args"] as? [Any] ?? []
        if function == "__openFileDialog" {
            return (await Self.openFileDialog(args, over: webView.window), nil)
        }
        return (window.perform(function, args), nil)
    }

    /// `SteamClient.System.OpenFileDialog`: the chosen path, or for a
    /// dismissed panel a rejection with `EResult` Cancelled, which the
    /// pickers ignore. Any other rejection shows as an error (Add Library
    /// Folder puts it in a dialog).
    private static func openFileDialog(_ args: [Any], over window: NSWindow?) async -> Any {
        let options = SteamFileDialogs.Options(args.first as? [String: Any] ?? [:])
        guard let chosen = await SteamFileDialogs.choose(options, over: window) else {
            return ["__sevoReject": ["result": SteamFileDialogs.cancelledResult, "message": "cancelled"]]
        }
        return chosen
    }

    /// Whether a message comes from Steam's UI: a window's top document on
    /// the bridge's origin, which popups inherit from their opener.
    nonisolated static func admitsMessage(
        isMainFrame: Bool,
        origin: (scheme: String, host: String, port: Int),
    ) -> Bool {
        isMainFrame && origin.scheme == "http" && origin.host == "127.0.0.1"
            && origin.port == Int(BridgePorts.steamUI)
    }
}
