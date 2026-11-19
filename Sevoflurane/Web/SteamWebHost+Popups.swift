import AppKit
import WebKit

extension SteamWebHost {
    func makeWebView(configuration: WKWebViewConfiguration) -> WKWebView {
        let webView = SteamWebView(
            frame: NSRect(x: 0, y: 0, width: 1280, height: 800),
            configuration: configuration,
        )
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        webView.allowsBackForwardNavigationGestures = false
        // Safari's inspector cannot attach without this.
        webView.isInspectable = WebInspection.isAllowed
        // WebKit's opaque base flashes white on every popup and blocks menu
        // transparency.
        if webView.responds(to: Selector(("_setDrawsBackground:"))) {
            webView.setValue(false, forKey: "drawsBackground")
        }
        // Off until the popup names itself (`SteamWindow.applyOcclusionPolicy`):
        // the context page and pop-up-level panels would be judged occluded
        // at once.
        SteamWebHost.setOcclusionDetection(false, on: webView)
        return webView
    }

    /// Lets WebKit stop rendering a covered page; private API, so guarded by
    /// `responds(to:)`.
    static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        guard webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:")))
        else { return }
        webView.setValue(enabled, forKey: "windowOcclusionDetectionEnabled")
    }

    /// Supplies the web view for Steam's `window.open`; the window around it
    /// waits for the shim to name the popup.
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

        // A popup the shim never names still gets a window.
        Task(name: "Adopt orphan popup") { [weak popup] in
            try? await Task.sleep(for: .milliseconds(400))
            popup?.adopt(name: "", parameters: "")
        }
        return webView
    }

    /// A window feature WebKit actually measured. WebKit fills an omitted
    /// `left`/`top` with `INT_MIN`, and a window two billion points
    /// off-screen crashes the process in its layer geometry.
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

    /// The top-left of a named window, in Steam's coordinates.
    func steamOrigin(ofWindowNamed name: String) -> CGPoint? {
        popups.values.first { $0.name == name }?.steamOrigin
    }

    func windowDidHide(_ window: SteamWindow) {
        guard window === desktop else { return }
        ActivationPolicy.recedeIfLastWindow(closing: window.nsWindow)
    }

    /// Puts the compatibility strip, the library's badges and the Mac filter
    /// on or off every open page to match Settings.
    func applyCompatibilityStrip() {
        let on = Preferences.compatibilityStrip
        // Read by the strip's `playsInThisSteam`.
        let steamForMac = "window.__sevoSteamForMac = \(Preferences.offersSteamForMac);\n"
            + "window.__sevoNativeBuildsOn = \(Engine.running.supportsSteamPlayMacOS);\n"
        desktop?.webView.evaluateJavaScript(steamForMac + (on ? SteamCompatBadge.script : SteamCompatBadge.removalScript))
        install(
            on ? SteamLibraryCompat.contextScript : SteamLibraryCompat.contextRemovalScript,
            describedAs: "Mac compatibility in the library", settledAt: SteamLibraryCompat.settled,
        )
        desktop?.webView.evaluateJavaScript(on ? SteamLibraryCompat.script : SteamLibraryCompat.removalScript)
        for window in [desktop].compactMap(\.self) + popups.values {
            window.evaluateOnStorePages(steamForMac + (on ? SteamCompatBadge.storeScript : SteamCompatBadge.removalScript))
        }
    }

    /// Offers each game's macOS build (``SteamNativeBuilds``) when the
    /// running engine runs macOS builds. Called at every desktop adoption.
    func applyNativeBuilds() {
        let on = Engine.running.supportsSteamPlayMacOS
        install(
            on ? SteamNativeBuilds.contextScript : SteamNativeBuilds.contextRemovalScript,
            describedAs: "native macOS builds", settledAt: SteamNativeBuilds.settled,
        )
        desktop?.webView.evaluateJavaScript(on ? SteamNativeBuilds.script : SteamNativeBuilds.removalScript)
    }
}
