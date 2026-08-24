import AppKit
import WebKit

/// A web view whose first click counts.
///
/// A menu panel opens without key status, so every initial click in it is a
/// "first mouse". WKWebView's default answer spends that click on making the
/// panel key — Steam's menus then need one click to highlight and a second to
/// activate. In a panel the click always belongs to the page.
final class SteamWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        window is NSPanel || super.acceptsFirstMouse(for: event)
    }
}

// MARK: - WebKit plumbing

/// The WebKit delegates, kept off ``SteamWebHost`` so the observable state is
/// not also an `NSObject` full of protocol conformances.
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

/// The navigation policy shared by every web view hosting Steam content:
/// page traffic passes, `steam://` routes back into the client, and any
/// other scheme is cancelled — CEF intercepts unknown schemes, while
/// WKWebView would hand them to LaunchServices, launching the real Mac
/// Steam app.
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
