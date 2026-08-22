import AppKit
import WebKit

/// One of Steam's windows, hosted in a real `NSWindow`.
///
/// Under CEF each popup Steam opens is an OS window it owns, and
/// `SteamClient.Window` is the binding that drives it — show, hide, move,
/// resize, close. Nothing else in the UI knows how a window is made, so
/// pointing that one namespace at an `NSWindow` is enough to make Steam's own
/// chrome, its context menus, and its window controls work unmodified.
@MainActor
final class SteamWindow: NSObject {
    let webView: WKWebView
    private(set) var role: SteamWindowRole
    private(set) var name: String

    /// Steam asks for this on windows whose close button should park them
    /// rather than end them.
    private var hidesOnClose = false
    private var isClosed = false


    private var window: NSWindow?

    /// The hosting window's AppKit frame, for WebKit's window-frame delegate.
    /// Steam's menu placement flips a flyout upward when `window.screenY` says
    /// there is no room below, and WebKit answers that DOM API with a zero
    /// rect unless the UI delegate supplies the real frame.
    var appKitFrame: CGRect {
        window?.frame ?? .zero
    }

    private var requestedSize: CGSize
    private var requestedOrigin: CGPoint?
    private var minimumSize: CGSize?
    private var maximumSize: CGSize?

    /// Regions of the page the user may drag the window by, in web coordinates
    /// with the origin at the top-left of the content. Steam marks them with
    /// `-webkit-app-region: drag`; the desktop chrome script reports them here.
    private var dragRegions: [CGRect] = []

    private weak var host: SteamWebHost?

    init(webView: WKWebView, role: SteamWindowRole, name: String,
         size: CGSize, origin: CGPoint?, host: SteamWebHost?) {
        self.webView = webView
        self.role = role
        self.name = name
        requestedSize = size
        requestedOrigin = origin
        self.host = host
        super.init()
    }

    // MARK: - Window lifecycle

    /// Builds the `NSWindow` for this popup's role.
    ///
    /// The window starts hidden: Steam renders into a popup only after it is
    /// told the popup exists, and asks for it to be shown afterwards with
    /// `ShowWindow` or `BringToFront`. Creating it visible would flash an empty
    /// frame before the UI paints.
    func realize() {
        guard window == nil, role != .context else { return }

        let content = NSRect(origin: .zero, size: requestedSize)
        let window: NSWindow = switch role {
        case .menu, .keyboard:
            SteamPanel(contentRect: content)
        case .bigPicture:
            // BPM draws its own top bar flush with the content, leaving no
            // strip for overlaid traffic lights, so the title bar stays a real
            // one outside the page.
            NSWindow(contentRect: content,
                     styleMask: [.titled, .closable, .miniaturizable, .resizable],
                     backing: .buffered, defer: false)
        default:
            NSWindow(contentRect: content,
                     styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                 .fullSizeContentView],
                     backing: .buffered, defer: false)
        }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed

        switch role {
        case .desktop, .login, .controllerConfig, .auxiliary:
            // Steam draws its own title bar; the macOS one is reduced to the
            // traffic lights floating over it, and Steam's duplicate buttons
            // are hidden by the chrome script.
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = Self.steamBackground
            window.collectionBehavior.insert(.fullScreenPrimary)
            if role == .desktop {
                window.title = "Steam"
                window.setFrameAutosaveName("SteamDesktopWindow")
                // Steam's strip is 32pt tall; the bare titlebar's ~28pt sets
                // the traffic lights slightly high against Steam's own row. An
                // empty unified-compact toolbar is the supported way to ask
                // for the taller titlebar that centers them.
                window.toolbar = NSToolbar()
                window.toolbarStyle = .unifiedCompact
            }
        case .bigPicture:
            window.title = "Big Picture"
            window.backgroundColor = Self.steamBackground
            window.collectionBehavior.insert(.fullScreenPrimary)
        case .menu:
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .popUpMenu
            webView.underPageBackgroundColor = .clear
            // Menus stay ordered-in for their whole life, invisible at alpha
            // 0 — see `hide()`. Ordering in at realize time (adoption) means
            // even a menu's first show has no page-visibility gap, and
            // `hidesOnDeactivate` would order out and reopen the gap; Steam
            // dismisses menus on deactivation itself.
            window.hidesOnDeactivate = false
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        case .keyboard:
            // The keyboard floats over whatever is being typed into and stays
            // up while another app is frontmost.
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = true
            window.level = .floating
            window.hidesOnDeactivate = false
            webView.underPageBackgroundColor = .clear
        case .context:
            break
        }

        let container = SteamContentView(frame: content)
        container.owner = self
        // Every window relays: WKWebView's own tracking is key-window gated,
        // and with menus taking key, the desktop needs relayed hover exactly
        // when a menu is up — that is what keeps its mouse-out logic (menu
        // dismissal) alive.
        container.relaysHover = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        window.contentView = container

        if let minimumSize { window.contentMinSize = minimumSize }
        if let maximumSize { window.contentMaxSize = maximumSize }

        if let requestedOrigin {
            window.setFrameOrigin(
                SteamScreenSpace.appKitOrigin(steamX: requestedOrigin.x,
                                              steamY: requestedOrigin.y,
                                              size: window.frame.size))
        } else if role == .desktop {
            window.center()
        }
        self.window = window
        if role == .menu {
            window.orderFront(nil)
        }
    }

    /// Debug tap for diagnosing menu placement: every `SteamClient.Window`
    /// call a menu window receives, appended to /tmp/sevoflurane-menu-calls.log.
    /// Remove once supernav positioning is settled.
    private func logMenuCall(_ function: String, _ args: [Any]) {
        guard role == .menu else { return }
        let frame = window?.frame ?? .zero
        let line = "\(Date().timeIntervalSince1970) \(name) " +
            "\(function)(\(args.map { "\($0)" }.joined(separator: ", "))) " +
            "frame=\(Int(frame.minX)),\(Int(frame.minY)) \(Int(frame.width))x\(Int(frame.height))\n"
        if let data = line.data(using: .utf8),
           let handle = FileHandle(forWritingAtPath: "/tmp/sevoflurane-menu-calls.log") {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? line.write(toFile: "/tmp/sevoflurane-menu-calls.log",
                            atomically: false, encoding: .utf8)
        }
    }

    /// Answers one `SteamClient.Window` call. The return value crosses back to
    /// the page as the resolution of the promise the UI is awaiting, so it must
    /// stay JSON-representable.
    func perform(_ function: String, _ args: [Any]) -> Any? {
        logMenuCall(function, args)
        switch function {
        case "ShowWindow", "SetKeyFocus", "MarkLastFocused", "SetForegroundWindow":
            show(activating: true)
        case "BringToFront":
            // The argument is Steam's k_EWindowBringToFront* enum.
            // `k_EWindowBringToFrontWithoutForcingOS` is 2 — the bundle's
            // popup portal passes it for `bNoFocusWhenShown` windows (the
            // hover supernavs), and giving those key focus blurs the desktop,
            // whose blur handler dismisses the menu 30ms after it opens.
            show(activating: (args.first as? NSNumber)?.intValue != 2)
        case "HideWindow":
            hide()
        case "Close":
            close()
        case "Minimize":
            window?.miniaturize(nil)
        case "ToggleMaximize":
            window?.zoom(nil)
        case "ToggleFullScreen":
            window?.toggleFullScreen(nil)
        case "MoveTo", "MoveToLocation":
            // A third argument carries the target monitor's scale factor,
            // because on Windows these are physical pixels. AppKit points are
            // already the page's own units, so it is dropped.
            moveTo(x: number(args, 0), y: number(args, 1))
        case "ResizeTo":
            resizeTo(width: number(args, 0), height: number(args, 1))
        case "PositionWindowRelative":
            positionRelative(toWindowNamed: string(args, 0),
                             x: number(args, 1), y: number(args, 2),
                             width: number(args, 3), height: number(args, 4))
        case "SetMinSize":
            minimumSize = CGSize(width: number(args, 0), height: number(args, 1))
            window?.contentMinSize = minimumSize ?? .zero
        case "SetMaxSize":
            maximumSize = CGSize(width: number(args, 0), height: number(args, 1))
            window?.contentMaxSize = maximumSize ?? .zero
        case "SetHideOnClose":
            hidesOnClose = args.first as? Bool ?? false
        case "SetWindowFlashing":
            if args.first as? Bool ?? false {
                NSApp.requestUserAttention(.informationalRequest)
            }
        case "IsWindowMinimized":
            return window?.isMiniaturized ?? false
        case "IsWindowMaximized":
            return window?.isZoomed ?? false
        case "GetWindowDimensions", "GetWindowDetails":
            return dimensions()
        case "GetDefaultMonitorDimensions":
            return monitorDimensions()
        case "GetMousePositionDetails":
            let point = SteamScreenSpace.steamMouseLocation
            return ["x": point.x, "y": point.y]
        case "DefaultMonitorHasFullscreenWindow":
            return false
        case "GetWindowRestoreDetails":
            // Steam treats this as an opaque token and hands it back to
            // `PositionWindowRelative` to say *which* window a menu is being
            // placed against, so the name is what it needs to carry. Restoring
            // geometry from it is AppKit's job, through frame autosave.
            return name
        case "__adopt":
            adopt(name: string(args, 0), parameters: string(args, 1))
        case "__dragRegions":
            dragRegions = rects(args.first)
        case "__openLocalDirectory":
            // "Browse local files" and friends. Routed here by the shim; the
            // client's own handler would open Wine's explorer.exe.
            if let target = WinePath.macURL(fromWindowsPath: string(args, 0)) {
                NSWorkspace.shared.open(target)
            }
        case "__openExternalURL":
            if let url = URL(string: string(args, 0)),
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        case "__bv":
            performBrowserView(id: Int(number(args, 0)), method: string(args, 1),
                               args: Array(args.dropFirst(2)))
        default:
            // The rest of the namespace is window-manager plumbing with no
            // AppKit counterpart (compositing mode, gamepad display scale, VR
            // overlays). The UI calls them unconditionally.
            break
        }
        return nil
    }

    // MARK: - Adoption

    /// Applies the identity Steam gave the popup, which only reaches us once
    /// `window.open` has returned to the shim.
    ///
    /// `parameters` is the query of the `about:blank?…` URL the popup manager
    /// opens; it carries the size limits and creation flags that the standard
    /// window-features string has no room for.
    func adopt(name: String, parameters: String) {
        guard window == nil else { return }
        if !name.isEmpty {
            self.name = name
            role = SteamWindowRole(popupName: name)
        }
        let query = URLComponents(string: "about:blank?" + parameters)?
            .queryItems ?? []
        func value(_ key: String) -> CGFloat? {
            guard let raw = query.first(where: { $0.name == key })?.value,
                  let number = Double(raw) else { return nil }
            return CGFloat(number)
        }
        if let width = value("minwidth"), let height = value("minheight") {
            minimumSize = CGSize(width: width, height: height)
        }
        if let width = value("maxwidth"), let height = value("maxheight") {
            maximumSize = CGSize(width: width, height: height)
        }

        realize()
        host?.windowDidAdopt(self)
    }

    // MARK: - Geometry

    private func moveTo(x: CGFloat, y: CGFloat) {
        requestedOrigin = CGPoint(x: x, y: y)
        guard let window else { return }
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(steamX: x, steamY: y,
                                          size: window.frame.size))
    }

    private func resizeTo(width: CGFloat, height: CGFloat) {
        requestedSize = CGSize(width: width, height: height)
        guard let window else { return }
        // Resizing an AppKit window grows it downward from its origin; Steam
        // expects the top-left to stay put, as it does on Windows.
        let topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        window.setContentSize(requestedSize)
        window.setFrameTopLeftPoint(topLeft)
    }

    /// Places a menu against the window that opened it.
    ///
    /// Steam computes the offset as `menuLeft - parentWindow.screenX`, so the
    /// coordinates are relative to the parent's top-left in screen space, and
    /// the first argument is the parent's restore-details token.
    private func positionRelative(toWindowNamed parentName: String,
                                  x: CGFloat, y: CGFloat,
                                  width: CGFloat, height: CGFloat) {
        realize()
        guard let window else { return }
        let parent = host?.steamOrigin(ofWindowNamed: parentName) ?? .zero
        requestedSize = CGSize(width: width, height: height)
        window.setContentSize(requestedSize)
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(steamX: parent.x + x, steamY: parent.y + y,
                                          size: window.frame.size))
    }

    /// This window's top-left in the coordinates Steam measures in.
    var steamOrigin: CGPoint {
        guard let window else { return requestedOrigin ?? .zero }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        return CGPoint(x: rect.minX, y: rect.minY)
    }

    private func dimensions() -> [String: Any] {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        guard let window else {
            return ["x": requestedOrigin?.x ?? 0, "y": requestedOrigin?.y ?? 0,
                    "width": requestedSize.width, "height": requestedSize.height,
                    "screenWidth": screen.frame.width,
                    "screenHeight": screen.frame.height]
        }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        return ["x": rect.minX, "y": rect.minY,
                "width": window.contentLayoutRect.width,
                "height": window.contentLayoutRect.height,
                "screenWidth": screen.frame.width,
                "screenHeight": screen.frame.height]
    }

    private func monitorDimensions() -> [String: Any] {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return ["flHorizontalScale": screen.backingScaleFactor,
                "flVerticalScale": screen.backingScaleFactor,
                "nFullWidth": screen.frame.width,
                "nFullHeight": screen.frame.height,
                "nAvailableWidth": visible.width,
                "nAvailableHeight": visible.height,
                "nAvailableLeft": visible.minX,
                "nAvailableTop": SteamScreenSpace.flipLine - visible.maxY]
    }

    // MARK: - Visibility

    func show(activating: Bool) {
        realize()
        guard let window else { return }
        if !role.isPanel, NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        if role == .menu {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        if activating {
            if !role.isPanel { NSApp.activate() }
            window.makeKeyAndOrderFront(nil)
            // Until the web view is first responder, AppKit routes mouse-moved
            // events elsewhere and the page sees no hover — the "menus only
            // react after one click inside" symptom.
            if !role.isPanel, window.firstResponder === window {
                window.makeFirstResponder(webView)
            }
        } else {
            window.orderFront(nil)
        }
    }

    /// Puts the window away. A menu fades to nothing instead of ordering out:
    /// its page must stay `document.visibilityState == "visible"`, because
    /// Steam's popup state is synced to DOM visibility and the ~100ms gap
    /// between `orderFront` and WebKit marking the page visible reads as "the
    /// menu failed to appear" — the state flips back and a 30ms-delayed
    /// effect hides the window. That loop was the supernav blink.
    private func hide() {
        guard let window else { return }
        if role == .menu {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        } else {
            window.orderOut(nil)
        }
    }

    /// Ends the popup from our side. Closing the `NSWindow` alone would leave
    /// Steam's popup manager holding a window it still believes is open, so the
    /// browsing context is closed too and the page's own teardown follows.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.evaluateJavaScript("window.close()")
        detach()
    }

    // MARK: - Browser views

    /// Steam's embedded web content (store, community, profile), which CEF
    /// renders as a native child browser positioned over a placeholder in the
    /// page. Here each one is a child web view over the window's own web view,
    /// placed by the same bounds Steam computes.
    private var browserViews: [Int: BrowserViewChild] = [:]

    private func performBrowserView(id: Int, method: String, args: [Any]) {
        if method == "create" {
            guard let host, let container = window?.contentView else { return }
            browserViews[id]?.destroy()
            browserViews[id] = BrowserViewChild(id: id, container: container,
                                                hostPage: webView, host: host)
            return
        }
        guard let view = browserViews[id] else { return }
        switch method {
        case "load":
            view.load(string(args, 0))
        case "bounds":
            view.setBounds(x: number(args, 0), y: number(args, 1),
                           width: number(args, 2), height: number(args, 3))
        case "visible":
            view.setVisible(args.first as? Bool ?? false)
        case "reload":
            view.webView.reload()
        case "back":
            view.webView.goBack()
        case "forward":
            view.webView.goForward()
        case "focus":
            window?.makeFirstResponder(view.webView)
        case "postMessage":
            view.postMessage(type: string(args, 0), dataJSON: string(args, 1))
        case "destroy":
            view.destroy()
            browserViews.removeValue(forKey: id)
        default:
            break
        }
    }

    /// Drops the window and the page without asking the page to close itself.
    /// Used when WebKit has already closed the browsing context.
    func detach() {
        isClosed = true
        for view in browserViews.values { view.destroy() }
        browserViews.removeAll()
        webView.removeFromSuperview()
        if let window {
            window.delegate = nil
            window.orderOut(nil)
            window.close()
        }
        window = nil
        host?.windowDidClose(self)
    }

    /// Tells the popup its frame changed. Steam's popup manager listens for
    /// these on its own window, exactly as CEF posts them.
    private func notifyPage(_ message: String) {
        webView.evaluateJavaScript("window.postMessage('\(message)', '*')")
    }

    // MARK: - React hover relay

    /// Runs Steam's own `onMouseEnter`/`onMouseLeave` handlers for the
    /// element path under the cursor.
    ///
    /// In a key window React's hover works off WKWebView's own tracking, but
    /// a menu panel is never key — and there, no deliverable mouse event runs
    /// a React enter/leave handler: forwarded native events and script
    /// dispatches both reach the document and its React root listener with
    /// no handler firing (clicks work; hover does not — measured). The
    /// handlers are still right there on each node's `__reactProps$…`, so
    /// the native tracking calls them directly: diff the ancestor path under
    /// the cursor against the last one, leave the departed nodes, enter the
    /// new ones. This is what keeps a hover menu open (the menu root's enter
    /// handler arms Steam's keep-alive flag) and what highlights its rows.
    func relayReactHover(contentPoint: NSPoint, contentHeight: CGFloat) {
        let x = Int(contentPoint.x)
        let y = Int(contentHeight - contentPoint.y)
        webView.evaluateJavaScript("""
        (function (x, y) {
          var el = document.elementFromPoint(x, y) || document.documentElement;
          var path = [];
          for (var n = el; n; n = n.parentElement) path.push(n);
          var prev = window.__sevoHoverPath || [];
          function props(n) {
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            return k ? n[k] : null;
          }
          function ev(n, type) {
            return { target: el, currentTarget: n, clientX: x, clientY: y,
                     relatedTarget: null, bubbles: true, type: type, buttons: 0,
                     preventDefault: function () {}, stopPropagation: function () {},
                     nativeEvent: { clientX: x, clientY: y } };
          }
          prev.forEach(function (n) {
            if (path.indexOf(n) >= 0) return;
            var p = props(n);
            if (p && p.onMouseLeave) try { p.onMouseLeave(ev(n, "mouseleave")); } catch (e) {}
          });
          for (var i = path.length - 1; i >= 0; i--) {
            var n = path[i];
            if (prev.indexOf(n) >= 0) continue;
            var p = props(n);
            if (p && p.onMouseEnter) try { p.onMouseEnter(ev(n, "mouseenter")); } catch (e) {}
          }
          window.__sevoHoverPath = path;
          return "";
        })(\(x), \(y))
        """)
    }

    /// The cursor left the window: run the leave handlers for everything
    /// still marked hovered, so Steam's dismiss logic arms.
    func relayReactHoverExit() {
        webView.evaluateJavaScript("""
        (function () {
          var prev = window.__sevoHoverPath || [];
          window.__sevoHoverPath = [];
          prev.forEach(function (n) {
            var k = Object.keys(n).find(function (k) { return k.indexOf("__reactProps$") === 0; });
            var p = k ? n[k] : null;
            if (p && p.onMouseLeave) {
              try {
                p.onMouseLeave({ target: n, currentTarget: n, relatedTarget: null,
                                 bubbles: true, type: "mouseleave",
                                 preventDefault: function () {}, stopPropagation: function () {},
                                 nativeEvent: {} });
              } catch (e) {}
            }
          });
          return "";
        })()
        """)
    }

    /// Whether a point in the window's content view sits in a region the page
    /// declared draggable.
    func isDragRegion(contentPoint: NSPoint, contentHeight: CGFloat) -> Bool {
        let webPoint = CGPoint(x: contentPoint.x, y: contentHeight - contentPoint.y)
        return dragRegions.contains { $0.contains(webPoint) }
    }

    static let steamBackground = NSColor(srgbRed: 0.086, green: 0.106,
                                         blue: 0.133, alpha: 1)

    // MARK: - Argument decoding

    private func number(_ args: [Any], _ index: Int) -> CGFloat {
        guard index < args.count, let value = args[index] as? NSNumber else { return 0 }
        return CGFloat(value.doubleValue)
    }

    private func string(_ args: [Any], _ index: Int) -> String {
        guard index < args.count else { return "" }
        return args[index] as? String ?? ""
    }

    private func rects(_ value: Any?) -> [CGRect] {
        guard let raw = value as? [[NSNumber]] else { return [] }
        return raw.compactMap { numbers in
            guard numbers.count == 4 else { return nil }
            return CGRect(x: numbers[0].doubleValue, y: numbers[1].doubleValue,
                          width: numbers[2].doubleValue, height: numbers[3].doubleValue)
        }
    }
}

// MARK: - Browser view child

/// One embedded web page (store, community, profile) living as a native child
/// web view over a Steam window's page — the WKWebView stand-in for CEF's
/// BrowserView. Its cookies persist in the default website data store, so a
/// web login in the store survives app restarts.
@MainActor
private final class BrowserViewChild: NSObject {
    let webView: WKWebView

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
                MainActor.assumeIsolated { self?.fireHistoryChanged() }
            },
            webView.observe(\.title) { [weak self] view, _ in
                MainActor.assumeIsolated {
                    guard let self, let title = view.title else { return }
                    self.fire("set-title", "[\(Self.jsString(title))]")
                }
            },
        ]
    }

    private var observations: [NSKeyValueObservation] = []

    func load(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        webView.load(URLRequest(url: url))
    }

    /// Bounds arrive in CSS pixels from the top-left of the hosting page.
    func setBounds(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        guard let container else { return }
        webView.frame = CGRect(x: x,
                               y: container.bounds.height - y - height,
                               width: width, height: height)
    }

    func setVisible(_ visible: Bool) {
        webView.isHidden = !visible
    }

    func postMessage(type: String, dataJSON: String) {
        webView.evaluateJavaScript(
            "window.postMessage({type: \(Self.jsString(type)), data: \(dataJSON.isEmpty ? "null" : dataJSON)}, '*')")
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
            "window.__sevoBV && __sevoBV[\(id)] && __sevoBV[\(id)](\(Self.jsString(event)), \(argsJSON))")
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
        ["url": item.url.absoluteString,
         "key": String(UInt(bitPattern: ObjectIdentifier(item).hashValue), radix: 36)]
    }

    private static func jsString(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(escaped)\""
    }
}

extension BrowserViewChild: WKNavigationDelegate {
    func webView(_: WKWebView,
                 decidePolicyFor navigationAction: WKNavigationAction) async
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

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        let url = Self.jsString(webView.url?.absoluteString ?? "")
        fire("start-request", "[\(url)]")
        fire("start-loading", "[\(url)]")
    }

    func webView(_ webView: WKWebView, didFinish _: WKNavigation!) {
        fire("finished-request", "[\(Self.jsString(webView.url?.absoluteString ?? "")), "
             + "\(Self.jsString(webView.title ?? ""))]")
        fireHistoryChanged()
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: any Error) {
        loadError(webView, error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!,
                 withError error: any Error) {
        loadError(webView, error)
    }

    private func loadError(_ webView: WKWebView, _ error: any Error) {
        EventLog.shared.log(.page, "browser view load failed: \(error.localizedDescription)")
        fire("load-error", "[\((error as NSError).code), "
             + "\(Self.jsString(webView.url?.absoluteString ?? "")), "
             + "\(Self.jsString(error.localizedDescription))]")
        fireHistoryChanged()
    }
}

extension BrowserViewChild: WKUIDelegate {
    /// `target=_blank` in embedded web content is an external link; it belongs
    /// in the user's browser.
    func webView(_: WKWebView, createWebViewWith _: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction,
                 windowFeatures _: WKWindowFeatures) -> WKWebView? {
        if let url = navigationAction.request.url,
           url.scheme == "http" || url.scheme == "https" {
            NSWorkspace.shared.open(url)
        }
        return nil
    }
}

// MARK: - NSWindowDelegate

extension SteamWindow: NSWindowDelegate {
    func windowShouldClose(_: NSWindow) -> Bool {
        // The desktop window follows Steam's own tray behavior and the Mac
        // convention for a menu-bar app: closing it puts the client away
        // without ending the session.
        guard role != .desktop, !hidesOnClose else {
            window?.orderOut(nil)
            host?.windowDidHide(self)
            return false
        }
        close()
        return false
    }

    func windowDidResize(_: Notification) {
        notifyPage("window_resized")
    }

    func windowDidMove(_: Notification) {
        notifyPage("window_moved")
    }
}

// MARK: - Supporting views

/// A panel that can take key focus while borderless.
///
/// Steam's menus dismiss themselves when their window loses focus, which only
/// happens if it could hold focus in the first place — a plain borderless
/// `NSWindow` never becomes key, so every menu would stay on screen forever.
private final class SteamPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        hidesOnDeactivate = true
        worksWhenModal = true
        // Steam's hover menus track the cursor inside their own page; without
        // this a never-key panel starves its web view of mouse-moved events.
        acceptsMouseMovedEvents = true
    }

    override var canBecomeKey: Bool { true }
}

/// The window's content view, which decides where the window may be dragged
/// and, for panels, tracks the cursor on the page's behalf.
///
/// WebKit does not act on `-webkit-app-region: drag`, so the page reports those
/// regions and the hit test hands the drag back to AppKit for exactly those
/// rectangles. Everywhere else the click belongs to the page.
private final class SteamContentView: NSView {
    weak var owner: SteamWindow?

    /// Panels relay native hover into the web view's own responder methods.
    ///
    /// WKWebView's mouse tracking is `NSTrackingActiveInKeyWindow` and a menu
    /// panel opens without key status, so the page would see no cursor at all
    /// until a click makes the panel key — no `:hover`, no highlight, and
    /// Steam's own dismiss-on-mouse-out never arms. This `.activeAlways` area
    /// generates the events WKWebView's area would have, and forwarding the
    /// genuine `NSEvent`s drives the full native pipeline (WebKit passes
    /// foreign-tracking-area events straight to its event handler).
    var relaysHover = false {
        didSet { updateTrackingAreas() }
    }

    override func updateTrackingAreas() {
        trackingAreas.forEach(removeTrackingArea)
        super.updateTrackingAreas()
        guard relaysHover else { return }
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeAlways, .inVisibleRect, .mouseEnteredAndExited, .mouseMoved],
            owner: self, userInfo: nil))
    }

    /// Once the panel is key (after a click), WKWebView's own tracking is
    /// live and forwarding would double every event.
    private var shouldRelay: Bool {
        relaysHover && window?.isKeyWindow != true
    }

    /// WKWebView implements no public mouse responder selectors — calling
    /// `mouseEntered(with:)` on it falls through NSResponder's default, which
    /// forwards up the chain to this very view and recurses until the stack
    /// dies. These private selectors are WebKit's own entry points into the
    /// same event pipeline its tracking area would use.
    private static let simulateEnter = Selector(("_simulateMouseEnter:"))
    private static let simulateMove = Selector(("_simulateMouseMove:"))
    private static let simulateExit = Selector(("_simulateMouseExit:"))

    private func relay(_ selector: Selector, _ event: NSEvent) {
        guard shouldRelay, let webView = owner?.webView,
              webView.responds(to: selector) else { return }
        webView.perform(selector, with: event)
    }

    /// ~30Hz is plenty for hover, and every native move would flood the page
    /// with evaluate calls.
    private var lastReactRelay = ContinuousClock.Instant.now

    private func relayReact(_ event: NSEvent, throttled: Bool) {
        guard shouldRelay, let owner else { return }
        if throttled {
            let now = ContinuousClock.Instant.now
            guard now - lastReactRelay > .milliseconds(33) else { return }
            lastReactRelay = now
        }
        owner.relayReactHover(contentPoint: convert(event.locationInWindow, from: nil),
                              contentHeight: bounds.height)
    }

    override func mouseEntered(with event: NSEvent) {
        relay(Self.simulateEnter, event)
        relayReact(event, throttled: false)
    }

    override func mouseMoved(with event: NSEvent) {
        relay(Self.simulateMove, event)
        relayReact(event, throttled: true)
    }

    override func mouseExited(with event: NSEvent) {
        relay(Self.simulateExit, event)
        if shouldRelay { owner?.relayReactHoverExit() }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        if let owner, owner.isDragRegion(contentPoint: local,
                                         contentHeight: bounds.height) {
            return self
        }
        return super.hitTest(point)
    }

    override var mouseDownCanMoveWindow: Bool { true }
}
