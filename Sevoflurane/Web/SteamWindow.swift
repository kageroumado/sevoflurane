import AppKit
import WebKit

/// One of Steam's windows, hosted in a real `NSWindow`.
///
/// Under CEF each popup is an OS window driven through `SteamClient.Window`
/// (show, hide, move, resize, close); pointing that one namespace at an
/// `NSWindow` makes Steam's chrome, context menus and window controls work
/// unmodified.
@MainActor
final class SteamWindow: NSObject {
    let webView: WKWebView
    private(set) var role: SteamWindowRole
    private(set) var name: String

    /// Set by Steam on windows whose close button hides rather than closes.
    private var hidesOnClose = false
    private var isClosed = false

    var window: NSWindow?

    /// The backing window, for app-level policy decisions that must exclude
    /// it (a hiding window still reads as visible for a beat).
    var nsWindow: NSWindow? { window }

    /// The hosting window's AppKit frame, for WebKit's window-frame delegate
    /// (``SteamWebCoordinator``).
    var appKitFrame: CGRect {
        window?.frame ?? .zero
    }

    /// Whether the hosting window is ordered in. A menu and the game overlay
    /// stay ordered in at alpha 0 so their pages keep rendering, and count as
    /// visible only once faded in.
    var isWindowVisible: Bool {
        guard let window, window.isVisible else { return false }
        return (role != .menu && role != .gameOverlay) || window.alphaValue > 0
    }

    func ownsWindow(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    var requestedSize: CGSize
    var requestedOrigin: CGPoint?
    private var minimumSize: CGSize?
    private var maximumSize: CGSize?

    /// Regions the window may be dragged by, in web coordinates from the
    /// content's top-left, reported by the chrome scripts.
    private var dragRegions: [CGRect] = []

    weak var host: SteamWebHost?

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

    /// Lets a covered window stop rendering, per its role. Applied once the
    /// popup names itself; until then it keeps rendering.
    private func applyOcclusionPolicy() {
        SteamWebHost.setOcclusionDetection(
            role.allowsOcclusionDetection && !occlusionDetectionSuspended, on: webView,
        )
    }

    /// Keeps the page visible to WebKit while covered, for benchmark runs
    /// only.
    private var occlusionDetectionSuspended = false

    func suspendOcclusionDetection(_ suspended: Bool) {
        occlusionDetectionSuspended = suspended
        applyOcclusionPolicy()
    }

    /// Builds the `NSWindow` for this popup's role, hidden: Steam paints
    /// first and asks for `ShowWindow` or `BringToFront` afterwards.
    func realize() {
        guard window == nil, role != .context else { return }

        let content = NSRect(origin: .zero, size: requestedSize)
        let window = makeWindow(content: content)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Every window is rebuilt from the page that opened it.
        window.isRestorable = false
        applyRoleChrome(to: window)
        window.contentView = makeContentView(content: content)

        if let minimumSize { window.contentMinSize = minimumSize }
        if let maximumSize { window.contentMaxSize = maximumSize }
        place(window)
        self.window = window
        if role != .gameOverlay, let childLevel = host?.overlayChildLevel {
            // Opened while the overlay is up: ride just above it. This app is
            // never active over a game, so hiding on deactivation would make
            // the panel vanish at once.
            window.level = NSWindow.Level(rawValue: childLevel)
            window.hidesOnDeactivate = false
            // Steam places the panel for a screen-sized overlay; here the
            // overlay is the game's frame.
            if let overlay = host?.overlayFrame {
                window.setFrame(Self.frame(of: window.frame.size, centeredIn: overlay), display: false)
            }
        }
        if role == .menu || role == .gameOverlay {
            // Ordered in at alpha 0 (chrome sets it) so the page renders.
            window.orderFront(nil)
        } else if role == .toast {
            park(window)
        }
    }

    /// Builds the window again for `newRole`: the window class, level and
    /// chrome all follow the role. The page stays loaded; the old window goes
    /// without the close path, which would tell Steam the popup closed.
    private func rebuild(as newRole: SteamWindowRole) {
        role = newRole
        applyOcclusionPolicy()
        titleObservation = nil
        if let old = window {
            old.delegate = nil
            old.orderOut(nil)
            old.contentView = nil
        }
        window = nil
        realize()
    }

    /// The bare `NSWindow` for this popup's role, before any dressing.
    private func makeWindow(content: NSRect) -> NSWindow {
        if role != .gameOverlay, host?.isOverlayActive == true {
            // Opened while the overlay is up: a non-activating panel, so it
            // does not pull focus off the game.
            return SteamPanel(contentRect: content)
        }
        return switch role {
        case .menu, .keyboard, .dialog:
            SteamPanel(contentRect: content)
        case .toast:
            // Never shown; a window only so WebKit runs the page, which
            // drains Steam's toast queue on its dismissal timer.
            NSWindow(
                contentRect: content,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
            )
        case .gameOverlay:
            // Non-activating: if this app became frontmost, Wine would sink
            // the game below the Dock, between the game and the overlay. It
            // can still become key (SteamPanel.canBecomeKey).
            SteamPanel(contentRect: content)
        case .bigPicture:
            // BPM's top bar leaves no room for overlaid traffic lights.
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
    }

    /// The view the page is hosted in.
    private func makeContentView(content: NSRect) -> NSView {
        let container = SteamContentView(frame: content)
        container.owner = self
        // WKWebView's tracking is key-window gated, and the desktop needs
        // hover while a menu holds key for its menu-dismissal logic.
        container.relaysHover = true
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        return container
    }

    /// Keeps an auxiliary window's title in step with its page.
    var titleObservation: NSKeyValueObservation?

    // swiftlint:disable cyclomatic_complexity function_body_length
    /// Answers one `SteamClient.Window` call. The return value resolves the
    /// page's promise, so it must stay JSON-representable. One case per call
    /// the shim routes here.
    func perform(_ function: String, _ args: [Any]) -> Any? {
        switch function {
        case "ShowWindow", "SetKeyFocus", "MarkLastFocused", "SetForegroundWindow":
            show(activating: true)
        case "BringToFront":
            // `k_EWindowBringToFrontWithoutForcingOS` (2) marks
            // `bNoFocusWhenShown` windows (hover supernavs); giving those key
            // blurs the desktop, which dismisses the menu 30ms after it opens.
            show(activating: (args.first as? NSNumber)?.intValue != 2)
        case "HideWindow":
            hide()
        case "Close":
            close()
        case "Minimize":
            // Steam minimizes a chat it opened for a message; a never-shown
            // window would become a phantom in the Dock.
            if !heldForNotification { window?.miniaturize(nil) }
        case "ToggleMaximize":
            window?.zoom(nil)
        case "ToggleFullScreen":
            window?.toggleFullScreen(nil)
        case "MoveTo", "MoveToLocation":
            // The third argument (the monitor's scale factor, for Windows'
            // physical pixels) is dropped: AppKit points are the page's units.
            // Dialogs are placed by the app; Steam would put them bottom-left.
            if !isParked, role != .gameOverlay, role != .dialog,
               let point = geometry(args, at: 0 ..< 2, from: function) {
                moveTo(x: Self.clampedOffset(point[0]), y: Self.clampedOffset(point[1]))
            }
        case "ResizeTo":
            // The overlay follows the game's frame, not Steam's full-screen size.
            if role != .gameOverlay, let size = geometry(args, at: 0 ..< 2, from: function) {
                let size = Self.clampedSize(width: size[0], height: size[1])
                resizeTo(width: size.width, height: size.height)
            }
        case "PositionWindowRelative":
            if !isParked, role != .gameOverlay, let frame = geometry(args, at: 1 ..< 5, from: function) {
                let size = Self.clampedSize(width: frame[2], height: frame[3])
                positionRelative(
                    toWindowNamed: string(args, 0),
                    x: Self.clampedOffset(frame[0]),
                    y: Self.clampedOffset(frame[1]),
                    width: size.width,
                    height: size.height,
                )
            }
        case "SetMinSize":
            if let size = geometry(args, at: 0 ..< 2, from: function) {
                minimumSize = Self.clampedSize(width: size[0], height: size[1])
                window?.contentMinSize = minimumSize ?? .zero
            }
        case "SetMaxSize":
            if let size = geometry(args, at: 0 ..< 2, from: function) {
                maximumSize = Self.clampedSize(width: size[0], height: size[1])
                window?.contentMaxSize = maximumSize ?? .zero
            }
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
            // An opaque token Steam hands back to `PositionWindowRelative` to
            // name the window a menu is placed against.
            return name
        case "__adopt":
            adopt(name: string(args, 0), parameters: string(args, 1))
        case "__dragRegions":
            dragRegions = rects(args.first)
        case "__openLocalDirectory":
            // "Browse local files"; the client's handler would open Wine's
            // explorer.exe.
            if let target = SteamBottle.macURL(fromWindowsPath: string(args, 0)) {
                Self.reveal(target)
            }
        case "__browseScreenshots":
            // The first argument is the game id in both routes; the folder is
            // revealed rather than the screenshot the handle names.
            if let folder = SteamBottle.screenshots(forApp: string(args, 0)) {
                Self.reveal(folder)
            }
        case "__openSoundSettings":
            // The input recorded from is the Mac's, not the bottle's.
            if let panel = URL(
                string: "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            ) {
                NSWorkspace.shared.open(panel)
            }
        case "__openExternalURL":
            if let url = URL(string: string(args, 0)),
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        case "__playMacBuild":
            if let appID = Int(string(args, 0)) {
                MacBuildHandoff.playMacBuild(appID: appID)
            }
        case "__openCompanion":
            if let appID = Int(string(args, 0)) {
                CompanionHandoff.open(appID: appID)
            }
        case "__steamNotification":
            host?.noteSteamNotification(json: string(args, 0))
        case "__unreadChats":
            // The shim's NATIVE_TAPS.
            host?.noteUnreadChats((args.first as? NSNumber)?.intValue ?? 0)
        case "__gameAction":
            host?.noteGameAction(
                phase: string(args, 0),
                appID: string(args, 1),
                task: string(args, 2),
                actionID: string(args, 3),
            )
        case "__launchOptions":
            // The shim's CALLBACK_TAPS.
            host?.noteLaunchOptions(
                appID: Int(string(args, 0)) ?? 0,
                actionID: Int(string(args, 1)) ?? 0,
                json: string(args, 2),
                remembered: string(args, 3),
            )
        case "__overlayActivated":
            host?.noteOverlayActivated(
                active: ((args.first as? NSNumber)?.intValue ?? 0) != 0,
                appID: string(args, 1),
            )
        case "__steamCallFailure":
            host?.noteSteamCallFailure(string(args, 0))
        case "__installWizard":
            host?.noteInstallWizard(
                state: (args.first as? NSNumber)?.intValue ?? 0,
                appID: string(args, 1),
            )
        case "__jsError":
            // A page error the shim's guard caught, with the stack Steam's
            // error boundary swallows.
            host?.notePageError(string(args, 0))
        case "__bv":
            // Read through NSNumber so a stray `NaN` cannot trap `Int(_:)`.
            performBrowserView(
                id: (args.first as? NSNumber)?.intValue ?? 0,
                method: string(args, 1),
                args: Array(args.dropFirst(2)),
            )
        default:
            // Window-manager calls with no AppKit counterpart (compositing
            // mode, gamepad display scale, VR overlays).
            break
        }
        return nil
    }

    // swiftlint:enable cyclomatic_complexity function_body_length

    // MARK: - Adoption

    /// Applies the identity Steam gave the popup, sent by the shim once
    /// `window.open` returns. `parameters` is the query of the popup's
    /// `about:blank?…` URL, carrying size limits and creation flags.
    func adopt(name: String, parameters: String) {
        guard window == nil else {
            // The 400ms orphan fallback built the window first, as an
            // auxiliary one; the name lands for `/windows` and menu parent
            // lookups, and a name with a role of its own rebuilds the window
            // for that role, so a late desktop still becomes the host's.
            guard self.name.isEmpty, !name.isEmpty else { return }
            self.name = name
            let named = SteamWindowRole(popupName: name)
            EventLog.shared.log(.window, "late adoption: orphan popup is \(name) (\(named))")
            guard named != role else { return }
            let wasVisible = window?.isVisible == true
            rebuild(as: named)
            host?.windowDidAdopt(self)
            if wasVisible { show(activating: false) }
            return
        }
        if !name.isEmpty {
            self.name = name
            role = SteamWindowRole(popupName: name)
            applyOcclusionPolicy()
        } else {
            EventLog.shared.log(
                .window,
                "adopting orphan popup (\(Int(requestedSize.width))×\(Int(requestedSize.height)))",
            )
        }
        let query = URLComponents(string: "about:blank?" + parameters)?
            .queryItems ?? []
        // `Double("nan")` and `Double("inf")` both parse; these become
        // window sizes.
        func value(_ key: String) -> CGFloat? {
            guard let raw = query.first(where: { $0.name == key })?.value,
                  let number = Double(raw), number.isFinite else { return nil }
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

    // MARK: - Visibility

    /// Whether a show of the login window arrived while the host deferred it;
    /// ``SteamWebHost/releaseWindowHold()`` replays it.
    private(set) var showWasDeferredByHold = false

    /// A chat window Steam opened for an incoming message, kept built and off
    /// screen until something the user did asks for it.
    private(set) var heldForNotification = false

    /// Until when Steam's own show and focus calls leave another app in
    /// front: set for a window that came back after its client restarted
    /// while the user was elsewhere, since the booting page asks for focus.
    var staysBehindUntil: ContinuousClock.Instant?

    private var staysBehind: Bool {
        guard let staysBehindUntil, !NSApp.isActive else { return false }
        return ContinuousClock.now < staysBehindUntil
    }

    func show(activating: Bool) {
        realize()
        // The overlay is shown only through overlay activation, never by the
        // `ShowWindow`/`BringToFront` Steam sends at creation.
        guard role != .gameOverlay else { return }
        host?.noteWindowWillShow(self)
        // Over the overlay: ordered in without activating, so the game keeps
        // focus.
        if host?.isOverlayActive == true {
            window?.orderFrontRegardless()
            return
        }
        // Refusing the toast's show is the whole suppression; its page still
        // runs and drains Steam's queue.
        guard role.isShowable else { return }
        guard let window else { return }
        if role == .login, host?.defersLoginWindow == true {
            showWasDeferredByHold = true
            return
        }
        showWasDeferredByHold = false
        if role == .chat, !window.isVisible, host?.chatShowIsUnasked == true {
            // Backstop behind ``SteamChatAutoOpen``: a show with no press or
            // chat request behind it stays hidden until something asks.
            heldForNotification = true
            EventLog.shared.log(
                .window, "chat window \(name) opened by an incoming message — left to the notification",
            )
            return
        }
        heldForNotification = false
        if host?.clientIsStopping == true, role != .dialog {
            // A stopping client asks for its windows once more; nothing new
            // comes up.
            return
        }
        let becameRegular = !role.isPanel && NSApp.activationPolicy() != .regular
        if becameRegular {
            NSApp.setActivationPolicy(.regular)
        }
        if role == .menu {
            window.alphaValue = 1
            window.ignoresMouseEvents = false
        }
        guard activating, !staysBehind else {
            window.orderFront(nil)
            attachDialogToDesktop()
            return
        }
        attachDialogToDesktop()
        if becameRegular {
            // Promotion from `.accessory` takes effect only after the run loop
            // turns; activating in the same pass leaves the window behind the
            // frontmost app, gray and unclickable.
            DispatchQueue.main.async { [weak self] in self?.activate(window) }
        } else {
            activate(window)
        }
    }

    /// Brings the app and this window forward.
    private func activate(_ window: NSWindow) {
        if !role.isPanel {
            Activation().bringAppForward()
        }
        window.makeKeyAndOrderFront(nil)
        // Until the web view is first responder the page sees no hover.
        if !role.isPanel, window.firstResponder === window {
            window.makeFirstResponder(webView)
        }
    }

    /// Puts the window away. A menu or the overlay fades to alpha 0 instead
    /// of ordering out, keeping its page `visible`: Steam syncs popup state to
    /// DOM visibility, and the ~100ms gap after `orderFront` reads as a menu
    /// that failed to appear, which made the supernav blink.
    private func hide() {
        showWasDeferredByHold = false
        guard let window else { return }
        if role == .menu || role == .gameOverlay {
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        } else {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    /// Shows the overlay at the game's `frame` and `level` (the game window's
    /// level + 1, above a full-screen game), faded in, key, taking input,
    /// with the cursor shown.
    func showOverlay(frame: CGRect?, level: Int?) {
        guard role == .gameOverlay else { return }
        realize()
        guard let window else { return }
        if let frame { window.setFrame(frame, display: true) }
        if let level { window.level = NSWindow.Level(rawValue: level) }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        // Key for the overlay's typing, without activating the app. Shift+Tab
        // then lands here, so the host handles it (`installOverlayKeyMonitor`).
        window.makeKey()
        if window.firstResponder === window {
            window.makeFirstResponder(webView)
        }
        // The game hides the cursor, and its ShowCursor hook acts only inside
        // the game.
        NSCursor.unhide()
    }

    /// A panel of `size` centered in `bounds`, shrunk to fit inside it.
    nonisolated static func frame(of size: NSSize, centeredIn bounds: NSRect) -> NSRect {
        let fitted = NSSize(width: min(size.width, bounds.width), height: min(size.height, bounds.height))
        return NSRect(
            x: bounds.midX - fitted.width / 2, y: bounds.midY - fitted.height / 2,
            width: fitted.width, height: fitted.height,
        )
    }

    /// Orders an overlay child popup in or out with the overlay.
    func setOrderedIn(_ orderedIn: Bool) {
        guard let window else { return }
        if orderedIn {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    /// Takes the overlay off screen: invisible, click-through, back at the
    /// normal level, and ordered out. Used on dismissal and when a third app
    /// takes the front.
    func hideOverlay() {
        guard role == .gameOverlay, let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .normal
        // Ordered out to resign key; an invisible key window would eat the
        // Shift+Tab that reopens the overlay.
        window.orderOut(nil)
    }

    /// Hides a menu through the menu instance it renders for, which also
    /// takes down the owner window's full-size `ContextMenuMouseOverlay`;
    /// closing the popup from this side leaves that overlay eating every
    /// click. Answers whether an instance was found.
    func hideThroughSteam() async -> Bool {
        let script = """
        (function () {
          var el = document.querySelector('div[tabindex="0"]') || document.body;
          var key = Object.keys(el).filter(function (k) {
            return k.indexOf("__reactFiber") === 0;
          })[0];
          var node = key ? el[key] : null;
          for (var i = 0; node && i < 12; i++) {
            var props = node.memoizedProps;
            if (props && props.instance && typeof props.instance.Hide === "function") {
              props.instance.Hide();
              return true;
            }
            node = node.return;
          }
          return false;
        })()
        """
        return await ((try? webView.evaluateJavaScript(script)) as? Bool) ?? false
    }

    /// Ends the popup from our side, closing the browsing context too so
    /// Steam's popup manager does not keep it as open.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.evaluateJavaScript("window.close()")
        detach(reason: .steamClosedIt)
    }

    // MARK: - Browser views

    /// Steam's embedded web content (store, community, profile), each a child
    /// web view over this window's, placed by the bounds Steam computes.
    private var browserViews: [Int: BrowserViewChild] = [:]

    /// Whether the Store BrowserView is settled and visible: a WebKit
    /// lifecycle signal, which outlasts Steam's DOM selectors.
    var hasSettledStoreBrowserView: Bool {
        browserViews.values.contains {
            $0.isSettledAndVisible && $0.loadedHost?.contains("store.steampowered.com") == true
        }
    }

    /// Runs `script` in this window's embedded store pages.
    func evaluateOnStorePages(_ script: String) {
        for view in browserViews.values {
            view.evaluateOnStore(script)
        }
    }

    /// Puts `stylesheet` on this window's embedded web pages, or takes the
    /// custom style off them for `nil`.
    func styleWebPages(with stylesheet: String?) {
        for view in browserViews.values {
            view.setUserStylesheet(stylesheet)
        }
    }

    var browserViewStatuses: [BrowserViewChild.Status] {
        browserViews.values.map(\.status).sorted { $0.id < $1.id }
    }

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
            // Mirror the client's session first so the page paints signed in.
            WebSessionCookies.refresh()
            return
        }
        guard let view = browserViews[id] else { return }
        switch method {
        case "load":
            let url = string(args, 0)
            Task {
                await WebSessionCookies.settled()
                view.load(url)
            }
        case "bounds":
            if let bounds = geometry(args, at: 0 ..< 4, from: "browser view bounds") {
                view.setBounds(
                    x: bounds[0], y: bounds[1], width: bounds[2], height: bounds[3],
                )
            }
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

    /// Why a popup stopped existing, which decides whether the app fires its
    /// `unload` (``SteamWebHost/notifyPopupUnloaded(named:)``). Never fire it
    /// during page teardown: `CPopup.OnClose` then reads as the user closing
    /// the window, which for `SP DesktopLoginWindow` means quit.
    enum DetachReason: Equatable {
        /// The popup's own document went away while the context page lives on:
        /// Steam closed it, or the user did through its close button.
        case steamClosedIt
        /// The context page under the popup is being reloaded or rebuilt.
        case pageTeardown
        /// The app is on its way out.
        case appQuitting
    }

    /// Drops the window and the page without asking the page to close itself.
    func detach(reason: DetachReason) {
        isClosed = true
        for view in browserViews.values {
            view.destroy()
        }
        browserViews.removeAll()
        webView.removeFromSuperview()
        if let window {
            window.delegate = nil
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
            window.close()
        }
        window = nil
        host?.windowDidClose(self, reason: reason)
    }

    /// Tells the popup its frame changed, as CEF posts it.
    private func notifyPage(_ message: String) {
        webView.evaluateJavaScript("window.postMessage('\(message)', '*')")
    }

    func isDragRegion(contentPoint: NSPoint, contentHeight: CGFloat) -> Bool {
        let webPoint = CGPoint(x: contentPoint.x, y: contentHeight - contentPoint.y)
        return dragRegions.contains { $0.contains(webPoint) }
    }

    // MARK: - Argument decoding

    /// The named arguments as finite numbers, or `nil` when any is not.
    ///
    /// Steam sends `NaN` (a menu placed against a window that has gone).
    /// `-[NSWindow _reallySetFrame:]` raises on a non-finite frame, and the
    /// exception unwinds out of the Swift concurrency frame, skipping the pop
    /// of its executor-tracking record; the app then segfaults hours later in
    /// WebKit on the next `@MainActor` check.
    private func geometry(
        _ args: [Any], at indices: Range<Int>, from function: String,
    ) -> [CGFloat]? {
        var values: [CGFloat] = []
        for index in indices {
            guard index < args.count,
                  let raw = args[index] as? NSNumber,
                  CGFloat(raw.doubleValue).isFinite
            else {
                EventLog.shared.log(
                    .window,
                    "ignoring \(function) for \(name.isEmpty ? "an unnamed popup" : name): "
                        + "argument \(index) is not a finite number",
                )
                return nil
            }
            values.append(CGFloat(raw.doubleValue))
        }
        return values
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

// MARK: - Local folders

extension SteamWindow {
    /// How a path the page names is shown in the Finder.
    nonisolated enum Reveal: Equatable, Sendable {
        /// A plain folder, opened as a Finder window.
        case open(URL)
        /// A file or a package, selected in its enclosing folder. Opening one
        /// would launch it: an app, a script, a document's handler.
        case select(URL)
    }

    /// The Finder action for `url`, judged on the file system as it stands.
    nonisolated static func directoryToReveal(_ url: URL) -> Reveal {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        if values?.isDirectory == true, values?.isPackage != true { return .open(url) }
        return .select(url)
    }

    static func reveal(_ url: URL) {
        switch directoryToReveal(url) {
        case let .open(folder):
            NSWorkspace.shared.open(folder)
        case let .select(item):
            NSWorkspace.shared.activateFileViewerSelecting([item])
        }
    }
}

// MARK: - NSWindowDelegate

extension SteamWindow: NSWindowDelegate {
    func windowShouldClose(_: NSWindow) -> Bool {
        // The desktop window closes despite `SetHideOnClose`: hidden, its
        // library keeps animating and committing layer trees, costing CPU,
        // and WebKit's layer-commit path has crashed from that state.
        // `SteamWebHost.showSteam` builds a new one.
        guard role == .desktop || !hidesOnClose else {
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
