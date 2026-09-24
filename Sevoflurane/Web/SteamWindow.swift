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

    var window: NSWindow?

    /// The backing window, for app-level policy decisions that must exclude
    /// it (a hiding window still reads as visible for a beat).
    var nsWindow: NSWindow? { window }

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
        // A menu and the game overlay stay ordered in at alpha 0 so their
        // pages keep rendering; they count as visible only once faded in.
        return (role != .menu && role != .gameOverlay) || window.alphaValue > 0
    }

    /// Whether an AppKit window is this popup's, for hit-testing an event's
    /// window against the popup inventory.
    func ownsWindow(_ candidate: NSWindow) -> Bool {
        window === candidate
    }

    var requestedSize: CGSize
    var requestedOrigin: CGPoint?
    private var minimumSize: CGSize?
    private var maximumSize: CGSize?

    /// Regions of the page the user may drag the window by, in web coordinates
    /// with the origin at the top-left of the content. Steam marks them with
    /// `-webkit-app-region: drag`; the desktop chrome script reports them here.
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

    /// Lets a genuinely on-screen window stop rendering when it is covered.
    /// Deferred until the popup names itself, because until then every page is
    /// an anonymous `about:blank` and the safe default is to keep rendering.
    private func applyOcclusionPolicy() {
        SteamWebHost.setOcclusionDetection(
            role.allowsOcclusionDetection && !occlusionDetectionSuspended, on: webView,
        )
    }

    /// While suspended, the page stays visible to WebKit even when the window
    /// is covered. A profile scenario needs its animation frames to keep
    /// coming regardless of what sits in front of the window; nothing else
    /// should ask for this.
    private var occlusionDetectionSuspended = false

    func suspendOcclusionDetection(_ suspended: Bool) {
        occlusionDetectionSuspended = suspended
        applyOcclusionPolicy()
    }

    /// Builds the `NSWindow` for this popup's role.
    ///
    /// The window starts hidden: Steam renders into a popup only after it is
    /// told the popup exists, and asks for it to be shown afterwards with
    /// `ShowWindow` or `BringToFront`. Creating it visible would flash an empty
    /// frame before the UI paints.
    func realize() {
        guard window == nil, role != .context else { return }

        let content = NSRect(origin: .zero, size: requestedSize)
        let window = makeWindow(content: content)
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        // Steam's window model is the one that decides what exists: every
        // window here is rebuilt from the page that opened it, so AppKit's
        // own restoration has nothing to put back.
        window.isRestorable = false
        applyRoleChrome(to: window)
        window.contentView = makeContentView(content: content)

        if let minimumSize { window.contentMinSize = minimumSize }
        if let maximumSize { window.contentMaxSize = maximumSize }
        place(window)
        self.window = window
        if role != .gameOverlay, let childLevel = host?.overlayChildLevel {
            // Opened while the overlay is up — ride just above it rather than
            // at the normal level, where the overlay and game would hide it.
            // A `SteamPanel` hides itself when its app deactivates, and this
            // app is never the active one over a game, so that is turned off or
            // the popup would vanish the instant it appeared.
            window.level = NSWindow.Level(rawValue: childLevel)
            window.hidesOnDeactivate = false
        }
        if role == .menu || role == .gameOverlay {
            // Ordered in at alpha 0 (chrome sets it) so WebKit schedules the
            // page and it renders; the overlay is placed and faded in only
            // when the client says it is active (`setOverlayActive`).
            window.orderFront(nil)
        } else if role == .toast {
            park(window)
        }
    }

    /// The bare `NSWindow` for this popup's role, before any dressing.
    private func makeWindow(content: NSRect) -> NSWindow {
        if role != .gameOverlay, host?.isOverlayActive == true {
            // A popup opened while the overlay is up (its Settings, a dialog):
            // a non-activating panel, so it does not pull focus off the game.
            // `realize` levels it above the overlay, and `show` orders it in
            // without activating the app.
            return SteamPanel(contentRect: content)
        }
        return switch role {
        case .menu, .keyboard, .dialog:
            SteamPanel(contentRect: content)
        case .toast:
            // Borderless and never ordered in. It exists because WebKit only
            // schedules a web view that lives in a window, and the toast's
            // page has to run: it renders, starts its dismissal timer, and
            // drains Steam's toast queue. The Mac side of the notification is
            // posted from `SteamNotifications`.
            NSWindow(
                contentRect: content,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
            )
        case .gameOverlay:
            // A non-activating panel: clicking the overlay must not promote
            // this app to frontmost, because that drops the game out of focus
            // and Wine sinks the game window below the Dock — leaving the Dock
            // and every other window sandwiched between the game and the
            // overlay. Keeping the game frontmost keeps the two an adjacent
            // pair above everything else. It can still become key for the
            // overlay's own mouse and hover (SteamPanel.canBecomeKey).
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
    }

    /// The view the page is hosted in.
    private func makeContentView(content: NSRect) -> NSView {
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
        return container
    }

    /// Keeps an auxiliary window's title in step with its page.
    var titleObservation: NSKeyValueObservation?

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
            // Steam minimizes the chat it just opened for a message so it
            // flashes in the taskbar; miniaturizing a window that was never
            // shown would put a phantom in the Dock instead.
            if !heldForNotification { window?.miniaturize(nil) }
        case "ToggleMaximize":
            window?.zoom(nil)
        case "ToggleFullScreen":
            window?.toggleFullScreen(nil)
        case "MoveTo", "MoveToLocation":
            // A third argument carries the target monitor's scale factor,
            // because on Windows these are physical pixels. AppKit points are
            // already the page's own units, so it is dropped.
            // A dialog's place is the app's: Steam would put it bottom-left.
            if !isParked, role != .gameOverlay, role != .dialog,
               let point = geometry(args, at: 0 ..< 2, from: function) {
                moveTo(x: Self.clampedOffset(point[0]), y: Self.clampedOffset(point[1]))
            }
        case "ResizeTo":
            // Steam resizes the overlay to the whole screen; it follows the
            // game's frame instead (`setOverlayActive`).
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
                Self.reveal(target)
            }
        case "__browseScreenshots":
            // Steam's own handler opens the bottle's explorer.exe. The first
            // argument is the game id in both routes; the screenshot handle
            // the app menu passes with it names a file, and the folder is
            // what "show on disk" means.
            if let folder = SteamBottle.screenshots(forApp: string(args, 0)) {
                Self.reveal(folder)
            }
        case "__openSoundSettings":
            // The bottle's microphone panel configures a Wine device nobody
            // speaks into; the input this app records from is the Mac's.
            if let panel = URL(
                string: "x-apple.systempreferences:com.apple.Sound-Settings.extension",
            ) {
                NSWorkspace.shared.open(panel)
            }
        case "__openFileDialog":
            return openFileDialog(options: args.first as? [String: Any] ?? [:])
        case "__openExternalURL":
            if let url = URL(string: string(args, 0)),
               url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
            }
        case "__steamNotification":
            // The context page's toast subscription
            // (SteamWebHost.notificationScript), one decoded notification.
            host?.noteSteamNotification(json: string(args, 0))
        case "__unreadChats":
            // Tapped out of Steam's own unread-count post to the client
            // (the shim's NATIVE_TAPS).
            host?.noteUnreadChats((args.first as? NSNumber)?.intValue ?? 0)
        case "__gameAction":
            // The context page's game-action subscription reporting launch
            // progress (SteamWebHost.gameActionScript).
            host?.noteGameAction(
                phase: string(args, 0),
                appID: string(args, 1),
                task: string(args, 2),
                actionID: string(args, 3),
            )
        case "__launchOptions":
            // The shim's tap on Steam's launch-option request (its
            // CALLBACK_TAPS): the app answers it with a native alert.
            host?.noteLaunchOptions(
                appID: Int(string(args, 0)) ?? 0,
                actionID: Int(string(args, 1)) ?? 0,
                json: string(args, 2),
                remembered: string(args, 3),
            )
        case "__overlayActivated":
            // The context page's overlay subscription
            // (SteamWebHost.overlayScript): Shift+Tab toggled the in-game
            // overlay. The host places and shows the overlay window over the
            // game, or hides it and returns focus. The app id is carried so the
            // host can close it through Steam.
            host?.noteOverlayActivated(
                active: ((args.first as? NSNumber)?.intValue ?? 0) != 0,
                appID: string(args, 1),
            )
        case "__jsError":
            // A page-side error the shim's guard caught — the stack Steam's
            // own error boundary swallows. Diagnostic for the intermittent
            // library crash; goes to the event log a bug report attaches.
            host?.notePageError(string(args, 0))
        case "__bv":
            // An identity, not a measurement — read as an integer so a stray
            // `NaN` cannot trap `Int(_:)` on the way in.
            performBrowserView(
                id: (args.first as? NSNumber)?.intValue ?? 0,
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
            applyOcclusionPolicy()
        } else {
            EventLog.shared.log(
                .window,
                "adopting orphan popup (\(Int(requestedSize.width))×\(Int(requestedSize.height)))",
            )
        }
        let query = URLComponents(string: "about:blank?" + parameters)?
            .queryItems ?? []
        /// `Double("nan")` and `Double("inf")` both parse, and these values
        /// become window sizes — the same trap as the shim's numbers.
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

    /// Whether a Steam-driven show of the login window arrived while the host
    /// was deferring it (the onboarding wizard still up, or sign-in skipped).
    /// The window is built and ready; ``SteamWebHost/releaseWindowHold()``
    /// replays the show.
    private(set) var showWasDeferredByHold = false

    /// A chat window Steam opened for an incoming message, kept built and off
    /// screen until something the user did asks for it.
    private(set) var heldForNotification = false

    func show(activating: Bool) {
        realize()
        // The game overlay's visibility is the client's to decide, through
        // `setOverlayActive`; the `ShowWindow`/`BringToFront` Steam sends at
        // creation must not put it on screen over the game.
        guard role != .gameOverlay else { return }
        host?.noteWindowWillShow(self)
        // A popup opened while the overlay is up rides above it (a
        // non-activating panel levelled in `realize`) and is ordered in
        // without activating the app, so the game keeps focus.
        if host?.isOverlayActive == true {
            window?.orderFrontRegardless()
            return
        }
        // Steam asks for its toast to be shown the moment the page renders
        // one. Refusing here is the whole of the suppression: the popup still
        // exists and still runs, so Steam's own queue drains on schedule and
        // nothing downstream can tell it was never on screen.
        guard role.isShowable else { return }
        guard let window else { return }
        if role == .login, host?.defersLoginWindow == true {
            showWasDeferredByHold = true
            return
        }
        showWasDeferredByHold = false
        if role == .chat, !window.isVisible, host?.chatShowIsUnasked == true {
            // The backstop behind ``SteamChatAutoOpen``, which refuses Steam
            // the auto-open in the first place. A show that still arrives with
            // no press in this app and no request for a chat behind it is one
            // Steam decided on, so the window stays built and hidden until
            // something asks — the notification click, or the friends list.
            // Nothing else happens for it either: no Dock icon, and no
            // minimize or move of a window nobody has seen.
            heldForNotification = true
            EventLog.shared.log(
                .window, "chat window \(name) opened by an incoming message — left to the notification",
            )
            return
        }
        heldForNotification = false
        if host?.clientIsStopping == true, role != .dialog {
            // The client on its way out asks for its windows once more; the
            // library coming forward and taking key is not how a quit should
            // look. What is already on screen stays; nothing new comes up.
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
        guard activating else {
            window.orderFront(nil)
            attachDialogToDesktop()
            return
        }
        attachDialogToDesktop()
        if becameRegular {
            // Promotion from `.accessory` only takes effect once the run loop
            // turns. Activating in the same pass is swallowed: the window
            // comes up behind whatever was frontmost, its traffic lights stay
            // gray, and clicking it does nothing because as far as the window
            // server is concerned the app still isn't one that activates —
            // only a Cmd-Tab away and back fixes it.
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
        // Until the web view is first responder, AppKit routes mouse-moved
        // events elsewhere and the page sees no hover — the "menus only
        // react after one click inside" symptom.
        if !role.isPanel, window.firstResponder === window {
            window.makeFirstResponder(webView)
        }
    }

    /// Puts the window away. A menu fades to nothing instead of ordering out:
    /// its page must stay `document.visibilityState == "visible"`, because
    /// Steam's popup state is synced to DOM visibility and the ~100ms gap
    /// between `orderFront` and WebKit marking the page visible reads as "the
    /// menu failed to appear" — the state flips back and a 30ms-delayed
    /// effect hides the window. That loop was the supernav blink.
    private func hide() {
        showWasDeferredByHold = false
        guard let window else { return }
        if role == .menu || role == .gameOverlay {
            // Fade rather than order out: the overlay's page must keep
            // rendering so its next activation has no blank first frame, the
            // same reason a menu stays ordered in at alpha 0.
            window.alphaValue = 0
            window.ignoresMouseEvents = true
        } else {
            window.parent?.removeChildWindow(window)
            window.orderOut(nil)
        }
    }

    /// Shows the game overlay over the running game: placed at the game's
    /// `frame`, levelled just above the game (`level` = the game window's own
    /// level + 1, so it rides above a frontmost fullscreen game rather than at
    /// a fixed floating level below it), faded in, made key, input enabled,
    /// cursor shown. The host only calls this while the game — or this app,
    /// once the overlay has key — is frontmost, so the overlay never sits over
    /// a third application.
    func showOverlay(frame: CGRect?, level: Int?) {
        guard role == .gameOverlay else { return }
        realize()
        guard let window else { return }
        if let frame { window.setFrame(frame, display: true) }
        if let level { window.level = NSWindow.Level(rawValue: level) }
        window.alphaValue = 1
        window.ignoresMouseEvents = false
        window.orderFrontRegardless()
        // Key, so the overlay's own chat and search take the keyboard — but as
        // a non-activating panel, so becoming key never promotes the app and
        // drops the game out of focus. Shift+Tab (the overlay toggle) then
        // lands here rather than in the game's hook, so the host swallows it
        // and closes the overlay itself (`installOverlayKeyMonitor`).
        window.makeKey()
        if window.firstResponder === window {
            window.makeFirstResponder(webView)
        }
        // The game hides the cursor; the renderer's ShowCursor hook only acts
        // inside the game, so it is unhidden here for the app window.
        NSCursor.unhide()
    }

    /// Orders an overlay child popup in or out with the overlay it belongs to,
    /// so Settings and the like ride with it and vanish when it closes. A
    /// no-op once the popup's own window is gone.
    func setOrderedIn(_ orderedIn: Bool) {
        guard let window else { return }
        if orderedIn {
            window.orderFrontRegardless()
        } else {
            window.orderOut(nil)
        }
    }

    /// Takes the overlay off screen without ordering it out, so its page keeps
    /// rendering: invisible, click-through, and dropped back to a normal level
    /// so an alpha-0 window can never sit above — or intercept anything over —
    /// another application. Used both when the overlay is dismissed and when a
    /// third app takes the front.
    func hideOverlay() {
        guard role == .gameOverlay, let window else { return }
        window.alphaValue = 0
        window.ignoresMouseEvents = true
        window.level = .normal
        // Ordered out so the panel resigns key: while it was up it held key to
        // take the overlay's typing, and an invisible key window would keep
        // eating the keyboard — the game would never see the next Shift+Tab
        // that reopens the overlay.
        window.orderOut(nil)
    }

    /// Hides a menu the way Steam hides one itself: through the menu instance
    /// this popup renders for. The instance's owner window draws a full-size
    /// `ContextMenuMouseOverlay` for as long as it counts the menu as active;
    /// closing the popup from this side leaves that overlay up, and every
    /// click in the owner window dies on it. Answers whether an instance was
    /// found to hide.
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

    /// Ends the popup from our side. Closing the `NSWindow` alone would leave
    /// Steam's popup manager holding a window it still believes is open, so the
    /// browsing context is closed too and the page's own teardown follows.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        webView.evaluateJavaScript("window.close()")
        detach(reason: .steamClosedIt)
    }

    /// Steam's file picker, as an `NSOpenPanel`.
    ///
    /// Runs modally, which is what the caller expects: the client's own dialog
    /// blocks the call until the user answers, and the awaiting UI treats a
    /// cancel as `EResult.Cancelled` (25) rather than an empty path — an empty
    /// one would be taken for a real answer and added as a shortcut.
    private func openFileDialog(options: [String: Any]) -> Any? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = options["bChooseDirectory"] as? Bool ?? false
        panel.canChooseFiles = !panel.canChooseDirectories
        panel.allowsMultipleSelection = false
        if let title = options["strTitle"] as? String { panel.message = title }
        if let initial = options["strInitialFile"] as? String,
           let url = SteamBottle.macURL(fromWindowsPath: initial) {
            panel.directoryURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        }
        guard panel.runModal() == .OK, let chosen = panel.url else {
            return ["__sevoReject": ["result": 25]]
        }
        return SteamBottle.windowsPath(for: chosen)
    }

    // MARK: - Browser views

    /// Steam's embedded web content (store, community, profile), which CEF
    /// renders as a native child browser positioned over a placeholder in the
    /// page. Here each one is a child web view over the window's own web view,
    /// placed by the same bounds Steam computes.
    private var browserViews: [Int: BrowserViewChild] = [:]

    /// Whether the desktop's native Store BrowserView has reached a settled
    /// visible state. This is deliberately a WebKit lifecycle signal rather
    /// than a Steam DOM selector, which changes frequently across Steam UI
    /// releases.
    var hasSettledStoreBrowserView: Bool {
        browserViews.values.contains {
            $0.isSettledAndVisible && $0.loadedHost?.contains("store.steampowered.com") == true
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
            // Steam is about to load a web property into this view; mirror
            // the client's session first so it paints signed in.
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
            // A browser view's frame reaches AppKit too, by way of `NSView`.
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

    /// Why a popup stopped existing.
    ///
    /// Steam learns a popup is gone from its document's `unload`, and the app
    /// fires that itself (``SteamWebHost/notifyPopupUnloaded(named:)``). It is
    /// owed for a popup whose own document went away while the context page
    /// lives on, and it is poison for one that went because the page under it
    /// is being torn down: the listeners go with the page, and running
    /// `CPopup.OnClose` anyway tells Steam the user closed that window — which
    /// for `SP DesktopLoginWindow` means quit.
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
    /// Used when WebKit has already closed the browsing context.
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

    // MARK: - Argument decoding

    /// The named arguments as numbers AppKit can be given, or `nil` when any
    /// of them is not.
    ///
    /// JavaScript numbers are doubles, so `NaN` and `Infinity` cross the shim
    /// through `NSNumber` intact — and Steam produces them: a menu placed
    /// against a window that has gone computes `menuLeft - parent.screenX`
    /// against `undefined`. `-[NSWindow _reallySetFrame:]` *raises* on a
    /// non-finite frame rather than ignoring it, and that exception unwinds
    /// out of the Swift concurrency frame this shim call arrives on, which
    /// skips the pop of the thread's executor-tracking record. The app then
    /// segfaults on the next `@MainActor` isolation check — a different stack,
    /// in WebKit, hours later. So a bad number is refused here, where the
    /// blame still reads.
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
        // The desktop window ends when it is closed, and overrides Steam's
        // `SetHideOnClose` to do it: its page is the whole library, which
        // keeps a React tree animating and committing layer trees whether or
        // not the window is on screen. Ordering it out would leave the app's
        // most expensive surface running behind a window nobody can see —
        // paid for in CPU the entire time the client is "away", and in a
        // WebKit layer-commit path that has crashed the app twice from
        // exactly that state. `SteamWebHost.showSteam` builds a new one.
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
