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

    /// Whether the hosting window is ordered in, for the `/windows` inventory.
    /// A menu counts as visible only when faded in — it stays ordered in for
    /// its whole life at alpha 0.
    var isWindowVisible: Bool {
        guard let window, window.isVisible else { return false }
        return role != .menu || window.alphaValue > 0
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

    init(
        webView: WKWebView,
        role: SteamWindowRole,
        name: String,
        size: CGSize,
        origin: CGPoint?,
        host: SteamWebHost?,
    ) {
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
            NSWindow(
                contentRect: content,
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false,
            )
        default:
            NSWindow(
                contentRect: content,
                styleMask: [
                    .titled,
                    .closable,
                    .miniaturizable,
                    .resizable,
                    .fullSizeContentView,
                ],
                backing: .buffered,
                defer: false,
            )
        }
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        applyRoleChrome(to: window)

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
                SteamScreenSpace.appKitOrigin(
                    steamX: requestedOrigin.x,
                    steamY: requestedOrigin.y,
                    size: window.frame.size,
                ),
            )
        } else if role == .desktop {
            window.center()
        }
        self.window = window
        if role == .menu {
            window.orderFront(nil)
        }
    }

    /// The per-role window dressing: title bar treatment, background, level,
    /// and visibility behavior.
    private func applyRoleChrome(to window: NSWindow) {
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
    }

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Answers one `SteamClient.Window` call. The return value crosses back to
    /// the page as the resolution of the promise the UI is awaiting, so it must
    /// stay JSON-representable.
    ///
    /// One case per call the shim routes here — the switch's size mirrors
    /// Steam's API surface, not tangled logic, so the complexity metrics are
    /// silenced rather than the switch split along artificial lines.
    func perform(_ function: String, _ args: [Any]) -> Any? {
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
            positionRelative(
                toWindowNamed: string(args, 0),
                x: number(args, 1),
                y: number(args, 2),
                width: number(args, 3),
                height: number(args, 4),
            )
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
            if let target = SteamBottle.macURL(fromWindowsPath: string(args, 0)) {
                NSWorkspace.shared.open(target)
            }
        case "__openExternalURL":
            if let url = URL(string: string(args, 0)),
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        case "__gameAction":
            // The context page's game-action subscription reporting launch
            // progress (SteamWebHost.gameActionScript).
            host?.noteGameAction(
                phase: string(args, 0),
                appID: string(args, 1),
                task: string(args, 2),
            )
        case "__bv":
            performBrowserView(
                id: Int(number(args, 0)),
                method: string(args, 1),
                args: Array(args.dropFirst(2)),
            )
        default:
            // The rest of the namespace is window-manager plumbing with no
            // AppKit counterpart (compositing mode, gamepad display scale, VR
            // overlays). The UI calls them unconditionally.
            break
        }
        return nil
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Adoption

    /// Applies the identity Steam gave the popup, which only reaches us once
    /// `window.open` has returned to the shim.
    ///
    /// `parameters` is the query of the `about:blank?…` URL the popup manager
    /// opens; it carries the size limits and creation flags that the standard
    /// window-features string has no room for.
    func adopt(name: String, parameters: String) {
        guard window == nil else {
            // The 400ms orphan fallback won the race against Steam's real
            // adoption: the window is built, but the identity should still
            // land — the name is what `/windows` and menu parent lookups key
            // on.
            if self.name.isEmpty, !name.isEmpty {
                self.name = name
                EventLog.shared.log(.window, "late adoption: orphan popup is \(name)")
            }
            return
        }
        if !name.isEmpty {
            self.name = name
            role = SteamWindowRole(popupName: name)
        } else {
            EventLog.shared.log(
                .window,
                "adopting orphan popup (\(Int(requestedSize.width))×\(Int(requestedSize.height)))",
            )
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
            SteamScreenSpace.appKitOrigin(
                steamX: x,
                steamY: y,
                size: window.frame.size,
            ),
        )
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
    private func positionRelative(
        toWindowNamed parentName: String,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
    ) {
        realize()
        guard let window else { return }
        let parent = host?.steamOrigin(ofWindowNamed: parentName) ?? .zero
        requestedSize = CGSize(width: width, height: height)
        window.setContentSize(requestedSize)
        window.setFrameOrigin(
            SteamScreenSpace.appKitOrigin(
                steamX: parent.x + x,
                steamY: parent.y + y,
                size: window.frame.size,
            ),
        )
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
            return [
                "x": requestedOrigin?.x ?? 0,
                "y": requestedOrigin?.y ?? 0,
                "width": requestedSize.width,
                "height": requestedSize.height,
                "screenWidth": screen.frame.width,
                "screenHeight": screen.frame.height,
            ]
        }
        let rect = SteamScreenSpace.steamRect(from: window.frame)
        return [
            "x": rect.minX,
            "y": rect.minY,
            "width": window.contentLayoutRect.width,
            "height": window.contentLayoutRect.height,
            "screenWidth": screen.frame.width,
            "screenHeight": screen.frame.height,
        ]
    }

    private func monitorDimensions() -> [String: Any] {
        let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        return [
            "flHorizontalScale": screen.backingScaleFactor,
            "flVerticalScale": screen.backingScaleFactor,
            "nFullWidth": screen.frame.width,
            "nFullHeight": screen.frame.height,
            "nAvailableWidth": visible.width,
            "nAvailableHeight": visible.height,
            "nAvailableLeft": visible.minX,
            "nAvailableTop": SteamScreenSpace.flipLine - visible.maxY,
        ]
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
            browserViews[id] = BrowserViewChild(
                id: id,
                container: container,
                hostPage: webView,
                host: host,
            )
            return
        }
        guard let view = browserViews[id] else { return }
        switch method {
        case "load":
            view.load(string(args, 0))
        case "bounds":
            view.setBounds(
                x: number(args, 0),
                y: number(args, 1),
                width: number(args, 2),
                height: number(args, 3),
            )
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
        for view in browserViews.values {
            view.destroy()
        }
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

    /// Whether a point in the window's content view sits in a region the page
    /// declared draggable.
    func isDragRegion(contentPoint: NSPoint, contentHeight: CGFloat) -> Bool {
        let webPoint = CGPoint(x: contentPoint.x, y: contentHeight - contentPoint.y)
        return dragRegions.contains { $0.contains(webPoint) }
    }

    static let steamBackground = NSColor(
        srgbRed: 0.086,
        green: 0.106,
        blue: 0.133,
        alpha: 1,
    )

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
            return CGRect(
                x: numbers[0].doubleValue,
                y: numbers[1].doubleValue,
                width: numbers[2].doubleValue,
                height: numbers[3].doubleValue,
            )
        }
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
