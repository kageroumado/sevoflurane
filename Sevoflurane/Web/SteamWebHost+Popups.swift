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
        // Off until a role says otherwise: every page starts life as an
        // unnamed `about:blank` popup, and the two roles that must never be
        // marked hidden — the parked context page and the pop-up-level panels
        // — are exactly the ones the occlusion service would judge occluded
        // immediately. `SteamWindow.applyOcclusionPolicy` turns it back on
        // once the popup names itself.
        SteamWebHost.setOcclusionDetection(false, on: webView)
        return webView
    }

    /// Lets WebKit stop rendering a page whose window is covered. Private on
    /// `WKWebView`, so guarded by a `responds(to:)` check — a Steam release
    /// cannot affect this, but a WebKit one could.
    static func setOcclusionDetection(_ enabled: Bool, on webView: WKWebView) {
        guard webView.responds(to: Selector(("_setWindowOcclusionDetectionEnabled:")))
        else { return }
        webView.setValue(enabled, forKey: "windowOcclusionDetectionEnabled")
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

    func windowDidHide(_ window: SteamWindow) {
        guard window === desktop else { return }
        ActivationPolicy.recedeIfLastWindow(closing: window.nsWindow)
    }

    /// Draws the Mac compatibility strip on game pages and store pages, and
    /// the library's badges and "Plays on Mac" filter, or takes them off, to
    /// match the stored choice. Called at adoption and whenever Settings
    /// changes it, so a switch is visible on the page already open.
    func applyCompatibilityStrip() {
        let on = Preferences.compatibilityStrip
        desktop?.webView.evaluateJavaScript(on ? SteamCompatBadge.script : SteamCompatBadge.removalScript)
        install(
            on ? SteamLibraryCompat.contextScript : SteamLibraryCompat.contextRemovalScript,
            describedAs: "Mac compatibility in the library", settledAt: SteamLibraryCompat.settled,
        )
        desktop?.webView.evaluateJavaScript(on ? SteamLibraryCompat.script : SteamLibraryCompat.removalScript)
        for window in [desktop].compactMap(\.self) + popups.values {
            window.evaluateOnStorePages(on ? SteamCompatBadge.storeScript : SteamCompatBadge.removalScript)
        }
    }

    /// Offers each game's macOS build beside its Windows one
    /// (``SteamNativeBuilds``) when the client's engine runs macOS builds,
    /// and takes the offer off otherwise. Called at adoption, which follows
    /// every client start, so an engine switch is reflected with the client
    /// it boots.
    func applyNativeBuilds() {
        let on = Engine.running.supportsSteamPlayMacOS
        install(
            on ? SteamNativeBuilds.contextScript : SteamNativeBuilds.contextRemovalScript,
            describedAs: "native macOS builds", settledAt: SteamNativeBuilds.settled,
        )
        desktop?.webView.evaluateJavaScript(on ? SteamNativeBuilds.script : SteamNativeBuilds.removalScript)
    }
}
