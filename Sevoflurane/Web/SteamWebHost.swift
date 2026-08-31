import AppKit
import Observation
import os
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

    /// Whether the page is showing Steam's login window — the signed-out
    /// state in which Steam's services legitimately never initialize until
    /// the user acts. The supervisor holds its recovery ladder on this.
    var isAwaitingSignIn: Bool {
        popups.values.contains { $0.role == .login && $0.isWindowVisible }
    }

    /// The menu-bar mirror, refreshed when the desktop window comes up.
    @ObservationIgnored weak var menuMirror: SteamMenuMirror?

    /// Where Steam's notifications are re-posted as the Mac's.
    @ObservationIgnored weak var notifications: SteamNotifications?

    /// How many conversations are waiting, as Steam itself counts them.
    ///
    /// Steam's friends UI computes this and posts it to the client on every
    /// change, for the client's own tray badge
    /// (`SteamClient.WebChat.SetNumChatsWithUnreadPriorityMessages`). That
    /// call crosses the shim, which taps it — so the count is pushed, exactly
    /// when it changes, and nothing here has to ask.
    private(set) var unreadChats = 0

    /// The most recently played installed games, for the menu-bar extra —
    /// the same list Steam's own tray menu leads with.
    private(set) var recentGames: [RecentGame] = []

    /// What one profile run is asked to do. Parsed from the control
    /// endpoint's query string so the CLI and a curl invocation agree.
    nonisolated struct BenchmarkOptions: Sendable, Equatable {
        static let iterationRange = 1 ... 10

        var iterations = 5
        var target: String?
        /// Busy threads standing in for a game for the length of the run.
        var loadThreads = 0
        var loadQualityOfService: SyntheticLoad.QualityOfService = .default

        init() {}

        init(query: String) {
            for pair in query.split(separator: "&") {
                let parts = pair.split(separator: "=", maxSplits: 1)
                guard parts.count == 2 else { continue }
                let value = String(parts[1])
                switch parts[0] {
                case "iterations":
                    if let count = Int(value) {
                        iterations = min(max(count, Self.iterationRange.lowerBound), Self.iterationRange.upperBound)
                    }
                case "target":
                    target = value
                case "load":
                    loadThreads = max(0, Int(value) ?? 0)
                case "qos":
                    loadQualityOfService = SyntheticLoad.QualityOfService(rawValue: value) ?? .default
                default:
                    break
                }
            }
        }
    }

    /// One complete profile run, serialized because all three targets share
    /// Steam's desktop page and popup manager.
    struct BenchmarkReport: Encodable {
        let iterations: Int
        /// `visible`, `forced` (the window was covered, so occlusion
        /// detection was suspended for the run), or `hidden` (it stayed
        /// hidden — every step is then `skipped`).
        let desktopVisibility: String
        let load: BenchmarkLoad
        let hostBefore: HostSnapshot
        let hostAfter: HostSnapshot
        let samples: [BenchmarkSample]
        let summaries: [BenchmarkSummary]
    }

    struct BenchmarkLoad: Encodable {
        let threads: Int
        let qualityOfService: String
    }

    struct BenchmarkSample: Encodable {
        let iteration: Int
        let target: String
        let milliseconds: Double
        /// `ready`, `failed`, or `skipped`.
        let outcome: String
        let detail: String?
        /// The main thread's queueing delays while this step ran.
        let mainThread: MainThreadWatchdog.Snapshot
    }

    struct BenchmarkSummary: Encodable {
        let target: String
        let successfulSamples: Int
        let totalSamples: Int
        let p50Milliseconds: Double?
        let p95Milliseconds: Double?
        let maxMainThreadDelayMilliseconds: Double
    }

    enum BenchmarkFailure: LocalizedError {
        case alreadyRunning
        case desktopUnavailable
        case desktopHidden(String)
        case invalidTarget(String)
        case commandRejected(String)
        case readinessTimedOut(String)

        var errorDescription: String? {
            switch self {
            case .alreadyRunning: "a benchmark is already running"
            case .desktopUnavailable: "Steam desktop did not become visible"
            case let .desktopHidden(state): "desktop page is \(state) to WebKit — nothing renders"
            case let .invalidTarget(target): "unknown benchmark target: \(target)"
            case let .commandRejected(reply): "Steam rejected the command: \(reply)"
            case let .readinessTimedOut(signal): "timed out waiting for \(signal)"
            }
        }
    }

    private enum BenchmarkTarget: String, CaseIterable {
        case library
        case store
        case friends
    }

    private var benchmarkRunning = false
    private let benchmarkWatchdog = MainThreadWatchdog()
    private var evaluationSequence = 0
    private var evaluationPending: [Int: CheckedContinuation<String?, Never>] = [:]
    private var evaluationTimeouts: [Int: Task<Void, Never>] = [:]

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

    // MARK: - Friends, chat, and notifications

    /// Opens Steam's friends list as its own window.
    ///
    /// The friends list and every chat are ordinary popups of the UI this app
    /// already hosts, so they need nothing from the desktop window — which is
    /// the point: a menu-bar Steam is a launcher and a friends list, and the
    /// library is the optional part. Measured against a live client with
    /// `SP Desktop` hidden throughout.
    ///
    /// With messages waiting, this opens the oldest of them instead, the way
    /// clicking Steam's own tray badge does; Steam falls back to the plain
    /// list when nothing is unread.
    func openFriends() {
        runInContext(Self.friendsScript(unread: unreadChats > 0), describedAs: "friends list")
    }

    /// Opens one friend's chat window, by the 32-bit account id Steam's own
    /// chat calls take. Notification clicks land here.
    func openChat(accountID: String) {
        guard !accountID.isEmpty, let id = Int(accountID) else {
            openFriends()
            return
        }
        runInContext(Self.chatScript(accountID: id), describedAs: "chat with \(accountID)")
    }

    private func runInContext(_ script: String, describedAs what: String) {
        // The window comes forward with the app, the way any window opened
        // from a menu-bar item does. Cooperative activation declines a
        // request it cannot attribute to an event, so this happens now,
        // while the click is still the reason for it.
        NSApp.activate()
        Task(name: "Open \(what)") {
            let result = await evaluateInContext(script)
            EventLog.shared.log(.window, "\(what): \(result ?? "no answer")")
        }
    }

    /// One notification from the context page's subscription
    /// (``notificationScript``), already decoded and with its identities
    /// resolved.
    func noteSteamNotification(json: String) {
        guard let data = json.data(using: .utf8),
              let notification = try? JSONDecoder().decode(SteamNotification.self, from: data)
        else {
            EventLog.shared.log(.app, "unreadable notification payload: \(json.prefix(200))")
            return
        }
        notifications?.post(notification)
        // The bottle's hidden twin UI renders the same toast as a CEF window
        // of its own (`notificationtoasts_N_desktop`), bottom-right on the
        // real desktop. The supervisor's sweep would catch it eventually;
        // catching it on the event is what keeps it from ever being seen.
        Task(name: "Hide client toast twin") {
            for delay in [500, 1_500, 3_000] {
                try? await Task.sleep(for: .milliseconds(delay))
                let hidden = await ClientLifecycle.hideVisibleClientPopups()
                if !hidden.isEmpty {
                    EventLog.shared.log(
                        .client, "hid the client's toast twin: \(hidden.joined(separator: ", "))",
                    )
                    return
                }
            }
        }
    }

    /// The unread count Steam posts to the client, tapped on its way through
    /// the shim.
    func noteUnreadChats(_ count: Int) {
        let clamped = max(0, count)
        guard clamped != unreadChats else { return }
        unreadChats = clamped
        EventLog.shared.log(.client, "unread conversations: \(clamped)")
    }

    /// Opens the friends list, or the oldest unread conversation.
    ///
    /// `ShowChatUnreadMessages` is Steam's own "show me what is waiting": it
    /// picks the oldest unread chat and activates it, and opens the plain
    /// list when there is nothing unread after all.
    private static func friendsScript(unread: Bool) -> String {
        """
        (function () {
          var app = window.g_FriendsUIApp;
          if (!app || typeof app.GetDefaultBrowserContext !== "function") return "unavailable";
          var context = app.GetDefaultBrowserContext();
          if (!context) return "no browser context";
          var desktop = app.m_DesktopApp;
          if (\(unread ? "true" : "false")
              && desktop && typeof desktop.ShowChatUnreadMessages === "function") {
            desktop.ShowChatUnreadMessages(context);
            return "showing unread";
          }
          if (typeof app.ShowPopupFriendsList !== "function") return "unavailable";
          app.ShowPopupFriendsList(context, false, true);
          return "showing friends list";
        })()
        """
    }

    private static func chatScript(accountID: Int) -> String {
        """
        (function () {
          var app = window.g_FriendsUIApp;
          if (!app || !app.UIStore
              || typeof app.UIStore.ShowFriendChatDialogWhenReady !== "function") {
            return "unavailable";
          }
          var context = app.GetDefaultBrowserContext();
          if (!context) return "no browser context";
          app.UIStore.ShowFriendChatDialogWhenReady(context, \(accountID), true, true);
          return "showing chat";
        })()
        """
    }

    /// Subscribes the context page to Steam's own toast value.
    ///
    /// `CurrentToastSubscribableValue` is what Steam's toast component reads,
    /// so subscribing to it sees exactly the notifications Steam would have
    /// drawn — and the user's Steam notification settings, which are applied
    /// upstream of it, are honored without this app knowing they exist. The
    /// payload is deserialized by Steam's own per-type descriptor
    /// (`GetNotificationTargets()[type].proto`), so the schema can never
    /// drift from the client's.
    ///
    /// Identities are resolved here because only the page can resolve them:
    /// an account id is a persona in `friendStore`, an app id is a name in
    /// `appStore`. The words are written in ``SteamNotifications``.
    private static let notificationScript = """
    (function () {
      if (window.__sevoNotifications) return "already registered";
      var store = window.NotificationStore;
      if (!store || !store.CurrentToastSubscribableValue) return "unavailable";
      window.__sevoNotifications = true;
    
      /* SteamID64 = account id + this. */
      var BASE = BigInt("76561197960265728");
    
      function accountID(steamid) {
        try { return String(BigInt(steamid) - BASE); } catch (e) { return ""; }
      }
    
      function persona(steamid) {
        try {
          var id = Number(accountID(steamid));
          if (!id) return "";
          /* GetFriendState takes Steam's own CSteamID, of which it uses
             exactly one method. */
          var state = window.friendStore.GetFriendState(
            { GetAccountID: function () { return id; } });
          return (state && state.display_name) || "";
        } catch (e) { return ""; }
      }
    
      function appName(appid) {
        try {
          var app = window.appStore.GetAppOverviewByAppID(Number(appid));
          return (app && app.display_name) || "";
        } catch (e) { return ""; }
      }
    
      store.CurrentToastSubscribableValue.Subscribe(function (toast) {
        if (!toast) return;
        var data = toast.data;
        var fields = data && data.toObject ? data.toObject() : {};
        var out = {
          kind: toast.eType,
          source: toast.eSource,
          id: String(toast.notificationID),
          title: fields.title || "",
          body: fields.body || "",
          icon: fields.icon || "",
          steamid: String(fields.steamid || fields.steamid_sender || ""),
          appid: fields.appid ? String(fields.appid) : "",
          gameName: fields.game_name || "",
        };
        out.accountid = out.steamid ? accountID(out.steamid) : "";
        if (!out.title && out.steamid) out.title = persona(out.steamid);
        if (!out.gameName && out.appid) out.gameName = appName(out.appid);
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage(
            { fn: "__steamNotification", args: [JSON.stringify(out)] });
        } catch (e) {}
      });
      return "registered";
    })()
    """

    /// Registers the notification subscription, retrying while Steam's own
    /// stores are still coming up. Steam sends no "the UI is ready" signal,
    /// and `NotificationStore` is a global the bundle assigns partway through
    /// boot — the same gap ``SteamMenuMirror`` retries across.
    private func registerForNotifications() {
        Task(name: "Register Steam notifications") {
            for _ in 1 ... 10 {
                let result = await evaluateInContext(Self.notificationScript)
                if result == "registered" || result == "already registered" {
                    EventLog.shared.log(.app, "Steam notifications: \(result ?? "")")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            EventLog.shared.log(
                .app, "Steam notifications: NotificationStore never appeared",
            )
        }
    }

    // MARK: - Launch status

    /// A launch in flight, told by the client's own game-action events — the
    /// signal the menu bar's spinner used to guess at with a timer.
    struct GameLaunch: Equatable {
        let appID: Int
        var detail: String
    }

    private(set) var activeLaunch: GameLaunch?
    @ObservationIgnored private var launchClear: Task<Void, Never>?

    #if DEBUG
        /// A host with a library and no client behind it, for the gallery.
        /// Nothing here starts a page: the web views exist only after
        /// ``bootstrap()``, which the gallery never calls.
        static func preview(
            games: [RecentGame] = [], launching: GameLaunch? = nil,
            status: String = "Steam is ready", unreadChats: Int = 0,
        ) -> SteamWebHost {
            let host = SteamWebHost()
            host.recentGames = games
            host.activeLaunch = launching
            host.status = status
            host.unreadChats = unreadChats
            return host
        }
    #endif

    /// One `__gameAction` event from the context page's registrations
    /// (``gameActionScript``). The trail also lands in the log, so a slow
    /// launch explains itself after the fact.
    func noteGameAction(phase: String, appID: String, task: String) {
        switch phase {
        case "start":
            EventLog.shared.log(.client, "launch \(appID): \(task.isEmpty ? "begun" : task)")
            setLaunch(GameLaunch(appID: Int(appID) ?? 0, detail: "Preparing…"), clearAfter: 180)
        case "task":
            guard !task.isEmpty, task != "None" else { return }
            EventLog.shared.log(.client, "launch \(appID): \(task)")
            let id = Int(appID) ?? activeLaunch?.appID ?? 0
            setLaunch(GameLaunch(appID: id, detail: Self.launchTaskText(task)), clearAfter: 180)
        case "end":
            // The launch flow is done but the engine still has to put up its
            // first window; GameLaunchWatch ends the story when it does.
            EventLog.shared.log(.client, "launch flow finished — waiting for the game window")
            if var launch = activeLaunch {
                launch.detail = "Waiting for the game window…"
                setLaunch(launch, clearAfter: 20)
            }
        default:
            break
        }
    }

    /// The game's first window is up (``GameLaunchWatch``) — story over.
    func gameWindowDidAppear() {
        guard activeLaunch != nil else { return }
        launchClear?.cancel()
        activeLaunch = nil
    }

    private func setLaunch(_ launch: GameLaunch, clearAfter seconds: Int) {
        activeLaunch = launch
        launchClear?.cancel()
        launchClear = Task(name: "Launch status expiry") { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activeLaunch = nil
        }
    }

    /// Steam's launch-pipeline task names, in user words. `Show*` tasks are
    /// the launch dialogs (EULA, launch options, playtime controls) — those
    /// wait on the user, not the machine. Unknown names fall back to the raw
    /// identifier spaced out: honest beats silent.
    private static func launchTaskText(_ task: String) -> String {
        switch task {
        case "ProcessingInstallScript": "Running the install script…"
        case "VerifyingFiles": "Verifying files…"
        case "SynchronizingCloud": "Syncing cloud saves…"
        case "SynchronizingControllerConfig": "Syncing controller config…"
        case "ProcessingShaderCache": "Processing shaders…"
        case "DownloadingWorkshop": "Updating Workshop items…"
        case "KickingOtherSession": "Signing out another session…"
        case "CreatingProcess", "Completed": "Starting the game…"
        case "WaitingGameWindow": "Waiting for the game window…"
        default:
            task.hasPrefix("Show")
                ? "Waiting for you in the Steam window…"
                : task.reduce(into: "") { result, character in
                    if character.isUppercase, !result.isEmpty { result.append(" ") }
                    result.append(result.isEmpty ? character : Character(character.lowercased()))
                } + "…"
        }
    }

    /// Subscribes the context page to the client's game-action events; they
    /// come back through the popup message handler as `__gameAction`.
    /// Idempotent per page session, and a reload re-registers because the
    /// desktop window is re-adopted.
    private static let gameActionScript = """
    (function () {
      if (window.__sevoGameActions) return "already registered";
      if (!window.SteamClient || !SteamClient.Apps
          || !SteamClient.Apps.RegisterForGameActionStart) return "unavailable";
      window.__sevoGameActions = true;
      var post = function (args) {
        try {
          window.webkit.messageHandlers.sevoWindow
            .postMessage({ fn: "__gameAction", args: args });
        } catch (e) {}
      };
      SteamClient.Apps.RegisterForGameActionStart(function (id, appid, action) {
        post(["start", String(appid), String(action || "")]);
      });
      SteamClient.Apps.RegisterForGameActionTaskChange(function (id, appid, task) {
        post(["task", String(appid), String(task || "")]);
      });
      SteamClient.Apps.RegisterForGameActionEnd(function () {
        post(["end", "", ""]);
      });
      return "registered";
    })()
    """

    @ObservationIgnored private var context: SteamWindow?
    @ObservationIgnored private var contextWindow: NSWindow?
    @ObservationIgnored private var contextMoveObserver: (any NSObjectProtocol)?
    @ObservationIgnored private var popups: [ObjectIdentifier: SteamWindow] = [:]
    @ObservationIgnored private var coordinator: SteamWebCoordinator?

    private static let contextParkOrigin = CGPoint(x: -20_000, y: -20_000)

    /// Every window the host owns, for `sevo` diagnostics
    /// (control endpoint `GET /windows`).
    func windowInventory() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        if let contextWindow {
            rows.append([
                "name": "SharedJSContext",
                "role": "context",
                "frame": NSStringFromRect(contextWindow.frame),
                "visible": contextWindow.isVisible,
            ])
        }
        for popup in popups.values {
            rows.append([
                "name": popup.name,
                "role": String(describing: popup.role),
                "frame": NSStringFromRect(popup.appKitFrame),
                "visible": popup.isWindowVisible,
            ])
        }
        return rows
    }

    // MARK: - Boot

    /// Starts Steam's UI at launch rather than on first window open, mirroring
    /// the client itself: by the time the user asks for a window, the UI is
    /// already running and the window can be handed over immediately.
    func bootstrap() {
        guard context == nil else { return }
        installMenuDismissalGuard()

        let coordinator = SteamWebCoordinator(host: self)
        self.coordinator = coordinator

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.setValue(true, forKey: "developerExtrasEnabled")
        configuration.userContentController.addScriptMessageHandler(
            coordinator, contentWorld: .page, name: SteamWebCoordinator.handlerName,
        )

        let webView = makeWebView(configuration: configuration)
        // The name deliberately mirrors the title of the real client's context
        // page this window stands in for; it travels back to Steam through
        // GetWindowRestoreDetails.
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
            contentRect: NSRect(origin: Self.contextParkOrigin, size: CGSize(width: 1280, height: 800)),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        // A display-mode change (a game going fullscreen) makes the window
        // server relocate off-screen windows onto a live screen, where this
        // one showed as a bare white 1280×800 rectangle. Invisible and
        // click-through, so even a brief surfacing shows nothing — and the
        // move observer below puts it straight back.
        window.backgroundColor = .clear
        window.isOpaque = false
        window.ignoresMouseEvents = true
        window.isExcludedFromWindowsMenu = true
        window.collectionBehavior = [.stationary, .ignoresCycle]
        let container = NSView(frame: webView.frame)
        container.addSubview(webView)
        window.contentView = container
        window.orderBack(nil)
        contextWindow = window
        contextMoveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: window, queue: .main,
        ) { [weak window] _ in
            MainActor.assumeIsolated {
                guard let window, window.frame.origin != Self.contextParkOrigin else { return }
                EventLog.shared.log(
                    .window,
                    "context window moved to \(window.frame.origin) (display change) — re-parking",
                )
                window.setFrameOrigin(Self.contextParkOrigin)
            }
        }

        status = "starting Steam"
        PerfProbe.poi.emitEvent("PageBoot")
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

    /// Brings Steam's window up: showing the one that exists, rebuilding the
    /// page when the user closed it, and otherwise asking the booting UI for
    /// the library.
    ///
    /// Rebuilding is a page reload rather than a request for a new window,
    /// because the window model is the client's: `UpdateDesiredWindows` is
    /// driven by a native callback, and a window instance recreated by hand
    /// never renders its popup (measured — the instance appears, its
    /// `BrowserWindow` stays nil, and `SteamClient.UI.EnsureMainWindowCreated`
    /// reaches the bottle's client, not this page). A reload boots the UI the
    /// way it boots at launch, and the desktop window is adopted a second or
    /// so later.
    func showSteam() {
        if let desktop {
            // The window exists from the moment Steam's UI boots, but on no
            // route — a `-silent` client is the same until its tray item is
            // clicked. Routing it is what fills it, and it happens the first
            // time someone actually asks for the window rather than at
            // launch: a menu-bar app that puts a window on screen at login
            // is not a menu-bar app.
            if !hasRoutedDesktop {
                hasRoutedDesktop = true
                openLibrary()
            }
            desktop.show(activating: true)
            return
        }
        // Come forward now, while the user's click is still the reason for it.
        // The rebuilt window does not exist for another couple of seconds, and
        // by then cooperative activation no longer sees an event to attribute
        // the request to: it declines, and the window arrives behind whatever
        // was frontmost with its traffic lights gray.
        if NSApp.activationPolicy() != .regular {
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        if desktopWasClosed {
            reload()
        } else {
            openLibrary()
        }
    }

    /// Ends the Steam UI from our side, the way the window's close button
    /// does. Exposed so the control endpoint (and anything driving the app)
    /// can put Steam away without a click.
    func closeSteam() {
        desktop?.close()
    }

    /// One page's web process is every page's web process — they share a
    /// pool — so a single death is reported once per hosted view, fourteen
    /// times over. The first report that matters does the recovery and the
    /// rest are dropped; without this the reloads pile up inside each other
    /// and the boot that follows has to be reloaded again.
    ///
    /// The context page is the whole of Steam's JavaScript and the desktop
    /// window is rebuilt from it, so both take the same reload the supervisor
    /// uses. Any other popup is Steam's to re-create: detaching tells its
    /// popup manager the window is gone.
    func webProcessDidTerminate(for webView: WKWebView) {
        let window = self.window(for: webView)
        switch window?.role {
        case .context, .desktop, nil:
            guard !isRecoveringFromWebProcessDeath else { return }
            isRecoveringFromWebProcessDeath = true
            EventLog.shared.log(
                .page,
                "web content process died (\(window?.name ?? "an unadopted page")) — rebuilding the UI",
            )
            reload()
            // The flag normally clears when the desktop window is adopted; this
            // is the backstop for a reload that never gets that far, so a
            // second death is not ignored forever.
            Task(name: "Web process recovery backstop") {
                try? await Task.sleep(for: .seconds(30))
                isRecoveringFromWebProcessDeath = false
            }
        default:
            window?.detach()
        }
    }

    private var isRecoveringFromWebProcessDeath = false

    /// Whether the desktop window existed and the user closed it — the state
    /// that separates "rebuild the page" from "the UI is still booting".
    private var desktopWasClosed = false

    /// Whether this desktop window has been sent to a route yet. A freshly
    /// adopted one renders nothing until it is.
    private var hasRoutedDesktop = false

    /// The context boots its window on no route at all, the same way a
    /// `-silent` client does until its tray item is clicked. The route runs
    /// through Steam's own navigator in this page — `ExecuteSteamURL` would
    /// navigate the window the *bottle's* client owns instead.
    func openLibrary() {
        context?.webView.evaluateJavaScript("""
        (function () {
          var window_ = window.SteamUIStore && SteamUIStore.WindowStore
            && SteamUIStore.WindowStore.MainWindowInstance;
          var nav = window_ && window_.Navigator;
          if (!nav || typeof nav.Home !== "function") return false;
          nav.Home();
          return true;
        })()
        """)
    }

    /// Runs a repeatable, warm UI workload. It does not use DOM selectors:
    /// Library waits for two desktop frames, Store also waits for its native
    /// BrowserView to settle, and Friends waits for its adopted NSWindow.
    func runSmokeBenchmark(options: BenchmarkOptions) async throws -> BenchmarkReport {
        guard !benchmarkRunning else { throw BenchmarkFailure.alreadyRunning }
        benchmarkRunning = true
        defer { benchmarkRunning = false }

        let iterations = options.iterations
        let targets: [BenchmarkTarget]
        if let requestedTarget = options.target {
            guard let target = BenchmarkTarget(rawValue: requestedTarget) else {
                throw BenchmarkFailure.invalidTarget(requestedTarget)
            }
            targets = [target]
        } else {
            targets = BenchmarkTarget.allCases
        }
        let run = PerfProbe.benchmark.beginInterval(
            "SmokeScenario", id: PerfProbe.benchmark.makeSignpostID(),
            "load=\(options.loadThreads, privacy: .public)",
        )
        defer {
            PerfProbe.benchmark.endInterval(
                "SmokeScenario", run,
                "iterations=\(iterations),targets=\(targets.map(\.rawValue).joined(separator: ","))",
            )
        }

        let hostBefore = HostSnapshot.take()
        showSteam()
        try await waitForDesktopVisibility()
        let visibility = await ensureDesktopPageVisible()
        defer { desktop?.suspendOcclusionDetection(false) }

        let load = SyntheticLoad(
            threads: options.loadThreads, qualityOfService: options.loadQualityOfService,
        )
        load.start()
        defer { load.stop() }
        benchmarkWatchdog.start()
        defer { benchmarkWatchdog.stop() }
        // Let the load and the watchdog reach steady state before timing.
        try await Task.sleep(for: .milliseconds(500))
        _ = benchmarkWatchdog.snapshotAndReset()

        var samples: [BenchmarkSample] = []
        for iteration in 1 ... iterations {
            try Task.checkCancellation()
            for target in targets {
                if visibility == "hidden" {
                    samples.append(skippedSample(target: target, iteration: iteration))
                    continue
                }
                samples.append(try await benchmark(target: target, iteration: iteration))
            }
        }
        load.stop()
        return BenchmarkReport(
            iterations: iterations,
            desktopVisibility: visibility,
            load: BenchmarkLoad(
                threads: load.threadCount,
                qualityOfService: options.loadQualityOfService.rawValue,
            ),
            hostBefore: hostBefore,
            hostAfter: HostSnapshot.take(),
            samples: samples,
            summaries: targets.map { summary(for: $0, in: samples) },
        )
    }

    /// The desktop page as WebKit sees it. A covered window is `hidden` —
    /// animation frames stop and nothing measured below would ever complete
    /// — so occlusion detection is suspended for the run and the page
    /// re-read; `forced` means that was needed. A page still hidden after
    /// that is not on any screen, and the run reports it instead of timing it.
    private func ensureDesktopPageVisible() async -> String {
        guard let desktop else { return "hidden" }
        if await desktopPageVisibilityState(desktop) == "visible" { return "visible" }
        desktop.suspendOcclusionDetection(true)
        for _ in 0 ..< 20 {
            try? await Task.sleep(for: .milliseconds(100))
            if await desktopPageVisibilityState(desktop) == "visible" { return "forced" }
        }
        return "hidden"
    }

    private func desktopPageVisibilityState(_ desktop: SteamWindow) async -> String {
        await evaluateInWebView("String(document.visibilityState)", webView: desktop.webView) ?? "unknown"
    }

    private func skippedSample(target: BenchmarkTarget, iteration: Int) -> BenchmarkSample {
        BenchmarkSample(
            iteration: iteration, target: target.rawValue, milliseconds: 0,
            outcome: "skipped", detail: BenchmarkFailure.desktopHidden("hidden").errorDescription,
            mainThread: benchmarkWatchdog.snapshotAndReset(),
        )
    }

    private func benchmark(target: BenchmarkTarget, iteration: Int) async throws -> BenchmarkSample {
        switch target {
        case .library: try await benchmarkLibrary(iteration: iteration)
        case .store: try await benchmarkStore(iteration: iteration)
        case .friends: try await benchmarkFriends(iteration: iteration)
        }
    }

    private func benchmarkLibrary(iteration: Int) async throws -> BenchmarkSample {
        try await benchmarkStep(target: .library, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.libraryBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            try await self.waitForDesktopFrame()
        }
    }

    private func benchmarkStore(iteration: Int) async throws -> BenchmarkSample {
        try await benchmarkStep(target: .store, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.storeBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            // Store readiness belongs to the native BrowserView child. Its
            // load state remains reliable when Steam throttles Desktop rAFs.
            try await self.waitForStoreBrowserView()
        }
    }

    private func benchmarkFriends(iteration: Int) async throws -> BenchmarkSample {
        // An open Friends window would make the step trivially ready; close
        // it first so the sample is a real open, popup creation included.
        if friendsWindow != nil {
            do {
                try await closeFriendsFromSteam()
            } catch let failure as BenchmarkFailure {
                return BenchmarkSample(
                    iteration: iteration, target: BenchmarkTarget.friends.rawValue, milliseconds: 0,
                    outcome: "failed", detail: "before the step: \(failure.localizedDescription)",
                    mainThread: benchmarkWatchdog.snapshotAndReset(),
                )
            }
        }
        return try await benchmarkStep(target: .friends, iteration: iteration) {
            let reply = await self.evaluateInContext(Self.friendsBenchmarkScript)
            try self.requireBenchmarkCommand(reply)
            try await self.waitForFriendsWindow()
        }
    }

    private var friendsWindow: SteamWindow? {
        popups.values.first { $0.role == .friends }
    }

    /// Closes the Friends popup the way its close button does: from Steam's
    /// side, so the popup manager drops its record before our window goes.
    /// Closing our window first (`SteamWindow.close()`) races the page's own
    /// teardown, and Steam then keeps a record of a dead popup against which
    /// every later show request is a no-op.
    private func closeFriendsFromSteam() async throws {
        _ = await evaluateInContext(Self.friendsCloseScript)
        try await waitForReadiness("Steam to drop the Friends popup") { [weak self] in
            await self?.evaluateInContext(Self.friendsPopupGoneScript) == "true"
        }
        try await waitForReadiness("Friends window to close") { [weak self] in
            self?.friendsWindow == nil
        }
        // Steam's FriendsUI finishes its own teardown a moment after the
        // popup manager forgets the window.
        try await Task.sleep(for: .milliseconds(300))
    }

    private static let friendsCloseScript = """
    (function () {
      var manager = window.g_PopupManager;
      if (!manager || !manager.m_mapPopups) return "no popup manager";
      var closed = 0;
      manager.m_mapPopups.forEach(function (popup) {
        if (String(popup.m_strName).indexOf("friendslist") !== 0) return;
        try { popup.m_popup.close(); closed++; } catch (e) {}
      });
      return String(closed);
    })()
    """

    private func benchmarkStep(
        target: BenchmarkTarget, iteration: Int,
        operation: () async throws -> Void,
    ) async throws -> BenchmarkSample {
        let clock = ContinuousClock()
        let started = clock.now
        _ = benchmarkWatchdog.snapshotAndReset()
        let interval = PerfProbe.benchmark.beginInterval(
            "ScenarioStep", id: PerfProbe.benchmark.makeSignpostID(),
            "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public)",
        )
        do {
            try await operation()
            let milliseconds = started.duration(to: clock.now).milliseconds
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("ready", privacy: .public)",
            )
            return BenchmarkSample(
                iteration: iteration, target: target.rawValue, milliseconds: milliseconds,
                outcome: "ready", detail: nil,
                mainThread: benchmarkWatchdog.snapshotAndReset(),
            )
        } catch is CancellationError {
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("cancelled", privacy: .public)",
            )
            throw CancellationError()
        } catch {
            let milliseconds = started.duration(to: clock.now).milliseconds
            PerfProbe.benchmark.endInterval(
                "ScenarioStep", interval,
                "target=\(target.rawValue, privacy: .public),iteration=\(iteration, privacy: .public),outcome=\("failed", privacy: .public)",
            )
            return BenchmarkSample(
                iteration: iteration, target: target.rawValue, milliseconds: milliseconds,
                outcome: "failed", detail: error.localizedDescription,
                mainThread: benchmarkWatchdog.snapshotAndReset(),
            )
        }
    }

    private func waitForDesktopVisibility() async throws {
        try await waitForReadiness("visible desktop") { [weak self] in
            self?.desktop?.isWindowVisible == true
        }
    }

    private func waitForDesktopFrame() async throws {
        guard let webView = desktop?.webView else { throw BenchmarkFailure.desktopUnavailable }
        let token = UUID().uuidString
        let arm = """
        (function () {
          var token = \(JSLiteral.string(token));
          requestAnimationFrame(function () {
            requestAnimationFrame(function () { window.__sevoBenchmarkFrame = token; });
          });
          return token;
        })()
        """
        guard await evaluateInWebView(arm, webView: webView) == token else {
            throw BenchmarkFailure.commandRejected("could not arm desktop frame")
        }
        try await waitForReadiness("two desktop frames") { [weak self] in
            guard let desktop = self?.desktop else { return false }
            return await self?.evaluateInWebView(
                "String(window.__sevoBenchmarkFrame || '')", webView: desktop.webView,
            ) == token
        }
    }

    private func waitForStoreBrowserView() async throws {
        try await waitForReadiness("settled Store BrowserView") { [weak self] in
            self?.desktop?.hasSettledStoreBrowserView == true
        }
    }

    func storeBrowserViewStatuses() -> [BrowserViewChild.Status] {
        desktop?.browserViewStatuses ?? []
    }

    private func waitForFriendsWindow() async throws {
        try await waitForReadiness("visible Friends window") { [weak self] in
            self?.popups.values.contains { $0.role == .friends && $0.isWindowVisible } == true
        }
    }

    private func waitForReadiness(
        _ signal: String, timeout: Duration = .seconds(12),
        condition: () async -> Bool,
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            try Task.checkCancellation()
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw BenchmarkFailure.readinessTimedOut(signal)
    }

    private func requireBenchmarkCommand(_ reply: String?) throws {
        guard let reply, !["false", "0", "unavailable", "no browser context", "no navigator"].contains(reply)
        else { throw BenchmarkFailure.commandRejected(reply ?? "no reply") }
    }

    private func summary(for target: BenchmarkTarget, in samples: [BenchmarkSample]) -> BenchmarkSummary {
        let targetSamples = samples.filter { $0.target == target.rawValue }
        let timings = targetSamples.filter { $0.outcome == "ready" }.map(\.milliseconds).sorted()
        return BenchmarkSummary(
            target: target.rawValue,
            successfulSamples: timings.count,
            totalSamples: targetSamples.count,
            p50Milliseconds: Self.percentile(0.5, in: timings),
            p95Milliseconds: Self.percentile(0.95, in: timings),
            maxMainThreadDelayMilliseconds: targetSamples
                .map(\.mainThread.maxDelayMilliseconds).max() ?? 0,
        )
    }

    private static func percentile(_ fraction: Double, in sorted: [Double]) -> Double? {
        guard !sorted.isEmpty else { return nil }
        let index = Int((Double(sorted.count - 1) * fraction).rounded(.up))
        return sorted[index]
    }

    private static let libraryBenchmarkScript = """
    (function () {
      var window_ = window.SteamUIStore && SteamUIStore.WindowStore
        && SteamUIStore.WindowStore.MainWindowInstance;
      var nav = window_ && window_.Navigator;
      if (!nav || typeof nav.Home !== "function") return "no navigator";
      nav.Home();
      return "queued";
    })()
    """

    private static let storeBenchmarkScript = """
    (function () {
      if (typeof window.__sevoRunSteamURL !== "function") return "unavailable";
      return String(window.__sevoRunSteamURL("steam://store"));
    })()
    """

    private static let friendsPopupGoneScript = """
    (function () {
      var manager = window.g_PopupManager;
      if (!manager || !manager.m_mapPopups) return "true";
      var open = false;
      manager.m_mapPopups.forEach(function (popup) {
        if (String(popup.m_strName).indexOf("friendslist") === 0) open = true;
      });
      return String(!open);
    })()
    """

    private static let friendsBenchmarkScript = """
    (function () {
      var app = window.g_FriendsUIApp;
      if (!app || typeof app.GetDefaultBrowserContext !== "function") return "unavailable";
      var context = app.GetDefaultBrowserContext();
      if (!context || typeof app.ShowPopupFriendsList !== "function") return "no browser context";
      app.ShowPopupFriendsList(context, false, true);
      return "queued";
    })()
    """

    /// Evaluates a script in the hidden context page and returns its result,
    /// which the script must produce as a string — structured results cross
    /// as JSON. The completion-handler API is wrapped by hand because the
    /// async overlay traps when the script's value is `null`; here a stray
    /// null answers `nil` instead of crashing.
    func evaluateInContext(_ script: String) async -> String? {
        guard let webView = context?.webView else { return nil }
        return await evaluateInWebView(script, webView: webView)
    }

    /// Evaluates JavaScript with an app-owned timeout. WebKit does not offer a
    /// cancellation token for this API, so the late callback is ignored after
    /// the continuation has been resolved exactly once by the timeout.
    private func evaluateInWebView(
        _ script: String, webView: WKWebView, timeout: Duration = .seconds(20),
    ) async -> String? {
        evaluationSequence += 1
        let id = evaluationSequence
        // The round trip to the web content process and back: what the UI
        // waits on for every question it asks a page.
        let eval = PerfProbe.bridge.beginInterval(
            "WebKitEval", id: PerfProbe.bridge.makeSignpostID(), "eval=\(id, privacy: .public)",
        )
        defer { PerfProbe.bridge.endInterval("WebKitEval", eval, "eval=\(id, privacy: .public)") }
        return await withCheckedContinuation { continuation in
            evaluationPending[id] = continuation
            webView.evaluateJavaScript(script) { value, _ in
                self.finishEvaluation(id, value: value as? String)
            }
            evaluationTimeouts[id] = Task(name: "WebKit evaluation timeout") { [weak self] in
                do {
                    try await Task.sleep(for: timeout)
                } catch is CancellationError {
                    return
                } catch {
                    return
                }
                self?.finishEvaluation(id, value: nil)
            }
        }
    }

    private func finishEvaluation(_ id: Int, value: String?) {
        evaluationTimeouts.removeValue(forKey: id)?.cancel()
        evaluationPending.removeValue(forKey: id)?.resume(returning: value)
    }

    /// Runs a `steam://` URL against the handlers this page registered — the
    /// dispatch CEF's scheme interception ends in, without the client round
    /// trip. `ExecuteSteamURL` broadcasts to every UI including the bottle
    /// client's own, which then raises a real (visible) Wine window for
    /// dialogs like About; the local path keeps it in this process. The round
    /// trip remains as fallback for URLs only the client resolves.
    func executeSteamURL(_ url: URL) {
        let literal = JSLiteral.string(url.absoluteString)
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

    func windowDidAdopt(_ window: SteamWindow) {
        // Every adoption is a chance the root menus now exist — they are
        // created after the desktop window, so anchoring on the desktop alone
        // reads an empty strip. Re-reading an unchanged strip is a no-op.
        menuMirror?.refresh()
        if window.role == .login {
            window.webView.evaluateJavaScript(SteamDesktopChrome.popupScript)
        } else if window.role.hasSteamFocusBar {
            window.webView.evaluateJavaScript(SteamDesktopChrome.friendsChromeScript)
        } else if window.role.hasNativeTitleBar {
            window.webView.evaluateJavaScript(SteamDesktopChrome.nativeTitleBarScript)
        }
        guard window.role == .desktop else { return }
        desktop = window
        desktopWasClosed = false
        hasRoutedDesktop = false
        isRecoveringFromWebProcessDeath = false
        status = "Steam is ready"
        PerfProbe.poi.emitEvent("DesktopAdopted")
        EventLog.shared.log(.window, "desktop window adopted — Steam is ready")
        // Steam draws a Windows title bar because under CEF it owns a
        // borderless OS window. Hosted here its buttons duplicate the traffic
        // lights and its strip has nowhere for them to sit.
        window.webView.evaluateJavaScript(SteamDesktopChrome.script)
        Task(name: "Register game-action events") {
            let result = await evaluateInContext(Self.gameActionScript)
            EventLog.shared.log(.client, "game-action events: \(result ?? "no answer")")
        }
        registerForNotifications()
        refreshRecentGames()
    }

    func windowDidHide(_ window: SteamWindow) {
        guard window === desktop else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    // MARK: - Menu dismissal guard

    /// Steam dismisses its own menus, mostly. The notifications popover is
    /// the exception: on Windows it closes when its window loses focus, and
    /// here it never has focus to lose, so no click anywhere would ever close
    /// it. The guard restores the universal rule — a press outside a visible
    /// menu closes it — while giving Steam first right of refusal: a real
    /// context menu is gone well inside the grace period, and only a
    /// survivor is closed from this side.
    private func installMenuDismissalGuard() {
        menuDismissalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown],
        ) { [weak self] event in
            MainActor.assumeIsolated { self?.notePressOutsideMenus(event) }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
        ) { _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.closeMenusSurviving(after: .milliseconds(300)) }
            }
        }
    }

    @ObservationIgnored private var menuDismissalMonitor: Any?

    private func notePressOutsideMenus(_ event: NSEvent) {
        let visibleMenus = popups.values.filter { $0.role == .menu && $0.isWindowVisible }
        guard !visibleMenus.isEmpty else { return }
        if let pressed = event.window, visibleMenus.contains(where: { $0.ownsWindow(pressed) }) {
            return
        }
        closeMenusSurviving(after: .milliseconds(300))
    }

    private func closeMenusSurviving(after grace: Duration) {
        Task(name: "Close stubborn menus") { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self else { return }
            for menu in popups.values where menu.role == .menu && menu.isWindowVisible {
                EventLog.shared.log(
                    .window,
                    "menu \(menu.name) survived an outside press — closing it here",
                )
                menu.close()
            }
        }
    }

    func windowDidClose(_ window: SteamWindow) {
        popups.removeValue(forKey: ObjectIdentifier(window.webView))
        guard window === desktop else { return }
        desktop = nil
        desktopWasClosed = true
        // Steam's context menus are per-window popups it creates lazily and
        // then keeps: a dozen hidden web views accumulate behind one desktop
        // window, and closing that window from our side leaves them orphaned
        // (Steam only reaps them when it tears the window down itself). They
        // belong to the page that just went, so they go with it — otherwise
        // every close/open cycle strands another dozen.
        for popup in popups.values where popup.role == .menu {
            popup.detach()
        }
        menuMirror?.refresh()
        status = "Steam window closed"
        EventLog.shared.log(.window, "desktop window closed — its page is gone")
        NSApp.setActivationPolicy(.accessory)
    }

    func setStatus(_ value: String) {
        status = value
    }
}
