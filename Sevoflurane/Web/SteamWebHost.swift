import AppKit
import Observation
import os
import WebKit

/// Owns the web side of the app.
///
/// Steam's UI is one JavaScript context that renders its windows into popups
/// it opens itself: a hidden web view runs the context, and every popup it
/// opens is adopted into a real `NSWindow`.
///
/// Popups must be built from the context's own `WKWebViewConfiguration`,
/// which keeps them in one web content process so the opener can script them
/// across documents, as CEF lets it.
@MainActor
@Observable
final class SteamWebHost {
    /// Steam's own `steamui` bundle, served with the `SteamClient` shim
    /// injected and proxied to the client running in the bottle.
    static let uiURL = URL(string: "http://127.0.0.1:\(BridgePorts.steamUI)/")!

    private(set) var status = "idle"
    /// The desktop window, once Steam has opened it.
    private(set) var desktop: SteamWindow?

    /// Whether the page holds Steam's login window: the signed-out state, in
    /// which Steam's services never initialize until the user acts. The
    /// supervisor holds its recovery ladder on this. A reload detaches the
    /// popup, and Steam reads its document unloading as the user closing the
    /// sign-in window, which quits.
    var isAwaitingSignIn: Bool {
        Self.isAwaitingSignIn(popupRoles: popups.values.map(\.role))
    }

    /// Whether a page holding these popups is waiting on a sign-in. Never key
    /// this on visibility: a login window held off screen is still waiting on
    /// a human, and a stuck stop flag would switch the guard off.
    static func isAwaitingSignIn(popupRoles: some Sequence<SteamWindowRole>) -> Bool {
        popupRoles.contains(.login)
    }

    /// ``isAwaitingSignIn``, observable, for the setup assistant's finish
    /// button. Refreshed wherever a popup is adopted or closes.
    private(set) var hasLoginWindow = false

    func refreshLoginWindowState() {
        let awaiting = isAwaitingSignIn
        if hasLoginWindow != awaiting { hasLoginWindow = awaiting }
    }

    /// The login window, for paths that must bring it forward rather than
    /// rebuild the page under it.
    var loginWindow: SteamWindow? {
        popups.values.first { $0.role == .login }
    }

    /// While true (the onboarding wizard is up), a login window Steam asks to
    /// show stays built but off screen until the wizard's finish button.
    private(set) var isHoldingWindows = false

    /// Whether the user chose to use the app without signing in to Steam
    /// (Quick Launch only). The login window stays built and off screen, as
    /// under the setup hold, until the user asks for Steam, which clears this.
    var signInIsSkipped = Preferences.app.bool(forKey: SteamWebHost.signInSkippedKey) {
        didSet { Preferences.app.set(signInIsSkipped, forKey: Self.signInSkippedKey) }
    }

    private static let signInSkippedKey = "steamSignInSkipped"

    /// Whether a login window Steam asks to show stays off screen.
    var defersLoginWindow: Bool {
        isHoldingWindows || signInIsSkipped
    }

    /// Set while the supervisor brings the client down (a quit, a stop, a
    /// restart); `SteamWindow.show` ignores the window requests the client
    /// makes on its way out.
    private(set) var clientIsStopping = false

    /// Set and cleared by the daemon around each stop. A mark left set
    /// refuses every login window `show()` asks for, and every signed-out
    /// boot is such a stop.
    func beginClientStop() {
        clientIsStopping = true
    }

    func endClientStop() {
        clientIsStopping = false
    }

    func holdWindows() {
        isHoldingWindows = true
    }

    /// Lifts the hold and replays the show a login window deferred under it.
    func releaseWindowHold() {
        guard isHoldingWindows else { return }
        isHoldingWindows = false
        for popup in popups.values where popup.showWasDeferredByHold {
            popup.show(activating: true)
        }
    }

    /// The menu-bar mirror, refreshed when the desktop window comes up.
    @ObservationIgnored weak var menuMirror: SteamMenuMirror?

    /// Where Steam's notifications are re-posted as the Mac's.
    @ObservationIgnored weak var notifications: SteamNotifications?

    /// How many conversations are waiting, as Steam counts them: the shim
    /// taps the friends UI's
    /// `SteamClient.WebChat.SetNumChatsWithUnreadPriorityMessages` call,
    /// made on every change for the client's tray badge.
    private(set) var unreadChats = 0

    /// The most recently played installed games, for the menu-bar extra.
    private(set) var recentGames: [RecentGame] = []

    /// Every installed game, in the order ``LibraryIndex`` files them: the
    /// popover's index under the recent ones.
    private(set) var libraryGames: [RecentGame] = []

    var benchmarkRunning = false
    let mainQueueLatency = MainQueueLatencyProbe()
    let evaluator = JavaScriptEvaluator()

    /// When each game was first seen at Synchronizing.
    @ObservationIgnored private var cloudSyncSince: [Int: Date] = [:]

    /// The games held at Synchronizing longer than a sync takes. A game
    /// force-ended during its Steam Cloud sync stays there, and the client
    /// drops every launch of it until it restarts.
    private(set) var gamesHeldInCloudSync: Set<Int> = []

    /// How long a sync may run before its row says the client is holding the game.
    static let longestCloudSync: TimeInterval = 60

    private func noteCloudSyncs(in games: [RecentGame], at now: Date) {
        let syncing = Set(games.filter(\.isInCloudSync).map(\.id))
        cloudSyncSince = cloudSyncSince.filter { syncing.contains($0.key) }
        for id in syncing where cloudSyncSince[id] == nil { cloudSyncSince[id] = now }
        let held = Set(cloudSyncSince.filter { now.timeIntervalSince($0.value) > Self.longestCloudSync }.keys)
        if held != gamesHeldInCloudSync { gamesHeldInCloudSync = held }
    }

    /// Asks the page for the five most recently played installed games and
    /// for all of them, in one evaluation so both lists describe one moment.
    func refreshRecentGames() {
        Task(name: "Refresh recent games") { _ = await readInstalledGames() }
    }

    /// ``refreshRecentGames()`` for when the desktop window arrives and the
    /// app store is often still filling: retries every two seconds for up to
    /// a minute until the library has games.
    func refreshRecentGamesWhenLoaded() {
        Task(name: "Refresh recent games once the library loads") {
            for _ in 0 ..< 30 {
                if await readInstalledGames() { return }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    /// Reads ``recentGames`` and ``libraryGames``; answers whether the
    /// library had any.
    private func readInstalledGames() async -> Bool {
        guard let raw = await evaluateInContext(Self.installedGamesScript),
              let data = raw.data(using: .utf8),
              let answer = try? JSONDecoder().decode(InstalledGames.self, from: data)
        else { return false }
        noteCloudSyncs(in: answer.library, at: .now)
        if answer.recent != recentGames { recentGames = answer.recent }
        let library = LibraryIndex.sorted(answer.library)
        if library != libraryGames { libraryGames = library }
        return !answer.library.isEmpty
    }

    /// What ``installedGamesScript`` answers.
    private struct InstalledGames: Decodable {
        let recent: [RecentGame]
        let library: [RecentGame]
    }

    private static let installedGamesScript = """
    (function () {
      // Installed in this bottle: `installed` alone is also true for a
      // game another of the account's Steam clients has installed.
      var installed = (window.appStore ? appStore.allApps : [])
        .filter(function (a) {
          return a.local_per_client_data && a.local_per_client_data.installed && a.app_type === 1;
        });
      function row(a) {
        return { id: a.appid, name: a.display_name, displayStatus: a.display_status, sortAs: a.sort_as };
      }
      var recent = installed.slice()
        .sort(function (x, y) {
          return (y.rt_last_time_played || 0) - (x.rt_last_time_played || 0);
        })
        .slice(0, 5);
      return JSON.stringify({ recent: recent.map(row), library: installed.map(row) });
    })()
    """

    /// Runs a game by app id from the page, for the daemon.
    ///
    /// `forgettingChoice` first clears the launch option Steam remembers, so
    /// its `ShowLaunchOption` request reaches an answer given ahead of time
    /// (``launchOptionAnswers``) instead of being answered from memory.
    func launchGame(appID: Int, forgettingChoice: Bool = false) {
        context?.webView.evaluateJavaScript(
            forgettingChoice
                ? LaunchOptions.forgetAndRunScript(appID: appID)
                : SteamSurface.Call.runGame.invocation("String(\(appID))", "''", "-1", "100"),
        )
    }

    /// Launch options chosen before Steam asks, by app id, each used once:
    /// `sevo app launch --option <n>`.
    @ObservationIgnored var launchOptionAnswers: [Int: Int] = [:]

    /// The app whose launch-option alert is on screen, while it is.
    @ObservationIgnored var launchOptionPending: Int?
    /// The game action whose launch-option request was last taken up: the
    /// context page and the shim's tap can both report one request.
    @ObservationIgnored var launchOptionAction: Int?

    /// What a sweep of the client's popups spares now: the popup named after
    /// the game a launch is in flight for, and any unnamed desktop-UI popup,
    /// either of which may be the dialog the launch waits on. Nothing is
    /// spared while this app's own launch-option alert is asking.
    var launchPopupSparing: PopupSparing {
        guard let launch = activeLaunch, launchOptionPending != launch.appID else { return .none }
        return PopupSparing(exactBases: [gameName(launch.appID)], unclassifiedDesktopPopups: true)
    }

    /// The game's name as the library shows it, or as its config names it.
    func gameName(_ appID: Int) -> String {
        (recentGames + libraryGames).first { $0.id == appID }?.name
            ?? GameConfig.game(appID).name ?? "app \(appID)"
    }

    // MARK: - Friends, chat, and notifications

    /// Tells a chat window Steam opened for an incoming message from one
    /// opened for a click.
    @ObservationIgnored var chatPolicy = UnaskedChatPolicy(startingAt: .now)

    func noteUnreadChats(_ count: Int) {
        let clamped = max(0, count)
        guard clamped != unreadChats else { return }
        unreadChats = clamped
        EventLog.shared.log(.client, "unread conversations: \(clamped)")
    }

    // MARK: - Launch status

    /// A launch in flight, told by the client's own game-action events.
    struct GameLaunch: Equatable {
        let appID: Int
        var detail: String
        /// Which press opened this line: only that press may end it.
        var ticket = UUID()
        /// The client's id for this game action, which its `ShowLaunchOption`
        /// request is answered against.
        var actionID: Int?
    }

    private(set) var activeLaunch: GameLaunch?
    @ObservationIgnored private var launchClear: Task<Void, Never>?

    #if DEBUG
        /// A host with a library and no client behind it, for the gallery;
        /// no page starts until ``bootstrap()``. `library` defaults to
        /// `games`, small enough that the popover shows no index.
        static func preview(
            games: [RecentGame] = [], library: [RecentGame]? = nil, launching: GameLaunch? = nil,
            status: String = "Steam is ready", unreadChats: Int = 0,
        ) -> SteamWebHost {
            let host = SteamWebHost()
            host.recentGames = games
            host.libraryGames = LibraryIndex.sorted(library ?? games)
            host.activeLaunch = launching
            host.status = status
            host.unreadChats = unreadChats
            return host
        }
    #endif

    /// A launch has begun for this app id, on any path, from the client's own
    /// game-action event.
    var onGameLaunchStart: ((Int) -> Void)?

    /// An app started or stopped running
    /// (`GameSessions.RegisterForAppLifetimeNotifications`); the stop edge
    /// closes a run record.
    var onGameRunningChanged: ((_ appID: Int, _ running: Bool) -> Void)?

    /// The client showed an error for a game action: it refused or abandoned
    /// the launch.
    var onGameActionError: ((_ appID: Int, _ detail: String) -> Void)?

    /// The launch task the log last carried, as `appid:task`.
    var lastLoggedLaunchTask: String?

    /// Shortcut app id → adopted program id, for the programs Steam lists
    /// as non-Steam games (``SteamShortcuts/aliases(_:)``).
    @ObservationIgnored var shortcutPrograms: [Int: Int] = [:]

    /// The expected refusals already logged for this page load.
    private var loggedRefusals: Set<String> = []

    /// Logs what the page's error guard reported: an error as it arrived, an
    /// expected refusal once per page load.
    func notePageError(_ detail: String) {
        switch PageErrorTriage.verdict(for: detail) {
        case .error:
            EventLog.shared.log(.window, "page error — \(detail)")
        case let .missingChromiumAPI(name):
            EventLog.shared.log(
                .window,
                "page error — Steam's UI called \(name), a Chromium API WebKit does not have; "
                    + "supply it in supplyChromiumSurface (steamclient_shim.js) — \(detail)",
            )
        case let .expected(sentence):
            if loggedRefusals.insert(sentence).inserted {
                EventLog.shared.log(.page, "expected: \(sentence)")
            }
        }
    }

    // Overlay presence: shown only while active and while the game (or this
    // app, once the overlay has key) is frontmost.
    @ObservationIgnored var overlayActive = false
    @ObservationIgnored var overlayGame: WineWindowWatch.GameWindow?
    @ObservationIgnored var overlayAppID = ""
    /// Counts the overlay's activations, so work begun for one showing can
    /// tell it has been closed and opened again since.
    @ObservationIgnored var overlayShowings = 0
    /// The install wizard's latest state and update count, so a delayed check
    /// can tell whether the wizard moved on.
    @ObservationIgnored var installWizardState = 0
    @ObservationIgnored var installWizardUpdates = 0
    /// An install whose wizard the page rebuild cancelled, reopened once the
    /// rebuilt Steam window is on screen.
    @ObservationIgnored var installWizardToReopen: String?
    /// The refused-call messages already logged (``noteSteamCallFailure(_:)``).
    @ObservationIgnored var loggedSteamCallFailures: Set<String> = []
    /// The latest energy-preference pass; the next one waits behind it.
    @ObservationIgnored var energyUpdate: Task<Void, Never>?
    @ObservationIgnored var overlayFrontObserver: (any NSObjectProtocol)?
    @ObservationIgnored var overlayKeyMonitor: Any?

    /// The popups Steam opened while the overlay was up (its Settings,
    /// friends, dialogs), ordered in and out with it and closed with it.
    @ObservationIgnored var overlayChildren: [SteamWindow] = []

    /// The game's first window is up (``GameLaunchWatch``); the launch line
    /// clears.
    func gameWindowDidAppear() {
        guard activeLaunch != nil else { return }
        launchClear?.cancel()
        activeLaunch = nil
    }

    /// A Quick Launch program was pressed, which the client never hears of:
    /// opens the row's status line. Answers the line's ticket, or nil when a
    /// launch of this program already owns the line (the daemon answers that
    /// press 409).
    func beginProgramLaunch(appID: Int) -> UUID? {
        if activeLaunch?.appID == appID { return nil }
        let launch = GameLaunch(appID: appID, detail: String(localized: "Starting…"))
        setLaunch(launch, clearAfter: 180)
        onProgramLaunchPressed?(appID)
        return launch.ticket
    }

    /// A program's launch is with the helper: the watch and the recorder take
    /// their marks before the process can write ahead of the reply.
    var onProgramLaunchPressed: ((Int) -> Void)?

    /// The helper spawned the program: starts the window watch and run record
    /// through ``onGameLaunchStart``.
    func programDidStart(appID: Int) {
        let ticket = activeLaunch?.appID == appID ? activeLaunch?.ticket : nil
        setLaunch(
            GameLaunch(appID: appID, detail: String(localized: "Waiting for its window…"), ticket: ticket ?? UUID()),
            clearAfter: 180,
        )
        onGameLaunchStart?(appID)
    }

    /// The helper started nothing: clears the status line, only for the
    /// press whose ticket opened it.
    func endProgramLaunch(appID: Int, ticket: UUID?) {
        guard let ticket, activeLaunch?.appID == appID, activeLaunch?.ticket == ticket else { return }
        launchClear?.cancel()
        activeLaunch = nil
    }

    func setLaunch(_ launch: GameLaunch, clearAfter seconds: Int) {
        activeLaunch = launch
        launchClear?.cancel()
        launchClear = Task(name: "Launch status expiry") { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.activeLaunch = nil
        }
    }

    @ObservationIgnored var context: SteamWindow?
    @ObservationIgnored var contextWindow: NSWindow?
    @ObservationIgnored var popups: [ObjectIdentifier: SteamWindow] = [:]
    @ObservationIgnored var coordinator: SteamWebCoordinator?
    /// Watches the Styles folder while the custom style is on.
    @ObservationIgnored var userStylesWatch: FolderWatch?
    /// The custom stylesheet as last read; empty while the style is off.
    @ObservationIgnored var userStylesheet = ""

    // MARK: - Boot

    /// Starts Steam's UI at launch, as the client does, so a window the user
    /// asks for can be handed over immediately.
    func bootstrap() {
        guard context == nil else { return }
        installMenuDismissalGuard()
        installEnergyPreferenceMirror()
        applyUserStyles()
        createContextPage()
    }

    /// Boots a fresh context page: new web view, web content process and
    /// delegates. The rung above `reload()`: a web view whose content process
    /// is gone or wedged loads nothing, while WebKit's networking process
    /// keeps its socket to the bridge open and every eval times out.
    func rebuildContextPage() {
        EventLog.shared.log(
            .page, "rebuilding the UI page from scratch (\(popups.count) popups detached)",
        )
        // A desktop window on screen is shown again when the new page adopts it.
        let wasShowingDesktop = desktop?.nsWindow?.isVisible == true || desktopShowIsPending
        detachPopups(reason: .pageTeardown)
        desktop = nil
        desktopShowIsPending = wasShowingDesktop
        context?.webView.stopLoading()
        context?.webView.removeFromSuperview()
        context = nil
        contextWindow?.orderOut(nil)
        contextWindow = nil
        status = "restarting the UI"
        createContextPage()
    }

    private func createContextPage() {
        let coordinator = SteamWebCoordinator(host: self)
        self.coordinator = coordinator

        let configuration = WKWebViewConfiguration()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = true
        configuration.preferences.setValue(WebInspection.isAllowed, forKey: "developerExtrasEnabled")
        configuration.userContentController.addScriptMessageHandler(
            coordinator, contentWorld: .page, name: SteamWebCoordinator.handlerName,
        )

        let webView = makeWebView(configuration: configuration)
        // The real client's context page title; it travels back to Steam
        // through GetWindowRestoreDetails.
        let page = SteamWindow(
            webView: webView,
            role: .context,
            name: "SharedJSContext",
            size: CGSize(width: 1280, height: 800),
            origin: nil,
            host: self,
        )
        context = page

        // WebKit only schedules a web view that lives in a window. A
        // zero-size, transparent window at the origin keeps the page
        // `visible` with 60 Hz animation frames (occlusion detection is off
        // for this view) without showing up anywhere. The web view keeps its
        // 1280×800 frame, the viewport Steam's UI expects.
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: .zero),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
        )
        window.alphaValue = 0
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

        status = "starting Steam"
        PerfProbe.poi.emitEvent("PageBoot")
        EventLog.shared.log(.page, "booting the Steam UI from \(Self.uiURL.absoluteString)")
        loggedRefusals = []
        loadUI(in: webView)
    }

    /// Loads the UI once the bridge's session cookie is in the web views'
    /// store: the bridge answers 401 without it.
    private func loadUI(in webView: WKWebView) {
        Task(name: "Load the Steam UI") {
            await LoopbackSessionCookie.install()
            webView.load(URLRequest(url: Self.uiURL))
        }
    }

    func reload() {
        EventLog.shared.log(.page, "reloading the UI page (\(popups.count) popups detached)")
        // A desktop window on screen is shown again when the reload adopts it.
        let wasShowingDesktop = desktop?.nsWindow?.isVisible == true || desktopShowIsPending
        detachPopups(reason: .pageTeardown)
        desktop = nil
        desktopShowIsPending = wasShowingDesktop
        status = "reloading"
        loggedRefusals = []
        if let webView = context?.webView { loadUI(in: webView) }
    }

    /// Brings every Steam window in line with a changed ``StreamerMode`` by
    /// reloading the page: the mask is part of the served page and each web
    /// view's configuration, and text it already rewrote cannot be restored.
    func applyStreamerMode() {
        guard context != nil else { return }
        guard !isAwaitingSignIn else {
            EventLog.shared.log(
                .page,
                "streamer mode \(StreamerMode.isOn ? "on" : "off") — applies at the next reload; "
                    + "reloading at the login window would quit Steam",
            )
            return
        }
        EventLog.shared.log(.page, "streamer mode \(StreamerMode.isOn ? "on" : "off") — reloading the UI page")
        reload()
    }

    /// A reload a person asked for. Refused at the login window: a reload
    /// detaches the login popup, Steam reads that as the user closing it, and
    /// quits.
    func reloadAskedByUser() {
        guard !isAwaitingSignIn else {
            EventLog.shared.log(.page, "reload asked for at the login window — refused, it would quit Steam")
            return
        }
        reload()
    }

    /// Whether a detach loop over every popup is running, so a detach that
    /// reaches ``windowDidClose(_:reason:)`` by another route during page
    /// teardown still says nothing to Steam.
    private var isTearingDownPage = false

    /// Drops every adopted popup, telling each why; the one writer of
    /// ``isTearingDownPage``.
    private func detachPopups(reason: SteamWindow.DetachReason) {
        isTearingDownPage = true
        defer { isTearingDownPage = false }
        for popup in popups.values {
            popup.detach(reason: reason)
        }
        popups.removeAll()
    }

    /// Clears the windows a dead client left on screen, frozen and dimmed,
    /// keeping the context page; the fresh client's windows are adopted when
    /// it boots.
    func dismissWindows(reason: SteamWindow.DetachReason = .pageTeardown) {
        guard desktop != nil || !popups.isEmpty else { return }
        // A desktop window on screen comes back when the fresh client's page
        // adopts it, in front only if the app was in front: a restart nobody
        // asked for must not take the keyboard from another app.
        let wasShowingDesktop = reason == .pageTeardown
            && (desktop?.nsWindow?.isVisible == true || desktopShowIsPending)
        detachPopups(reason: reason)
        desktop = nil
        desktopWasClosed = true
        if wasShowingDesktop {
            desktopShowIsPending = true
            pendingShowActivates = NSApp.isActive
        }
        status = "reconnecting"
    }

    /// Brings Steam's window up: showing the one that exists, rebuilding the
    /// page when the user closed it, and otherwise asking the booting UI for
    /// the library.
    ///
    /// Rebuilding is a page reload: a window instance recreated by hand never
    /// renders its popup (its `BrowserWindow` stays nil, and
    /// `SteamClient.UI.EnsureMainWindowCreated` reaches the bottle's client).
    /// The reloaded desktop window is adopted a second or so later.
    func showSteam() {
        if let loginWindow, isAwaitingSignIn {
            // Signed out, the window to show is the login popup: a signed-out
            // desktop window shows empty, and a reload would quit Steam (see
            // ``isAwaitingSignIn``).
            EventLog.shared.log(
                .window, "asked for Steam while signed out — bringing the login window forward",
            )
            signInIsSkipped = false
            loginWindow.show(activating: true)
            return
        }
        if let desktop {
            // The window boots on no route, like a `-silent` client; it is
            // routed the first time someone asks for it, never at launch.
            EventLog.shared.log(
                .window,
                "asked for Steam — its window exists"
                    + "\(isSteamOnScreen ? " on screen" : " off screen")"
                    + "\(hasRoutedDesktop ? "" : " on no route; routing it"); bringing it forward",
            )
            if !hasRoutedDesktop {
                routeDesktop()
            }
            desktop.show(activating: true)
            return
        }
        // Activate now, while the click is still the reason: cooperative
        // activation declines a request seconds later, and the rebuilt window
        // would arrive behind the frontmost app with gray traffic lights.
        ActivationPolicy.becomeRegular(forAWindowWithin: ActivationPolicy.graceForAPromisedWindow)
        NSApp.activate()
        // Steam re-creates its desktop window hidden, so the request is held
        // until the adoption.
        desktopShowIsPending = true
        pendingShowActivates = true
        if desktopWasClosed {
            EventLog.shared.log(
                .window,
                "asked for Steam — its window was closed; reloading the page to rebuild it, "
                    + "and showing the desktop window the reload adopts",
            )
            reload()
        } else {
            EventLog.shared.log(
                .window,
                "asked for Steam — no desktop window yet (status: \(status)); "
                    + "routing and showing the one the booting UI creates",
            )
            routeDesktop()
        }
    }

    /// Whether a ``showSteam`` is waiting for the desktop window the page is
    /// building. Cleared by that adoption, and by a close.
    private var desktopShowIsPending = false

    /// Whether the pending show brings the window to the front: true for a
    /// show someone asked for, and for a window that was in front when its
    /// client restarted.
    private var pendingShowActivates = true

    /// How long after its adoption a booting desktop page goes on asking for
    /// focus.
    private static let bootingPageAsksForFocus: Duration = .seconds(20)

    /// Closes the desktop window as its close button does, for the control
    /// endpoint.
    func closeSteam() {
        desktop?.close()
    }

    /// The pages share one web process, so a single death is reported once
    /// per hosted view; the first report for the context or desktop reloads
    /// the page and the rest are dropped, or the reloads pile up. Any other
    /// popup is detached for Steam to re-create.
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
            // Adoption clears the flag; this backstop covers a reload that
            // never gets there. Each recovery has its own, ended with it.
            recoveryBackstop?.cancel()
            recoveryBackstop = Task(name: "Web process recovery backstop") {
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                isRecoveringFromWebProcessDeath = false
            }
        default:
            window?.detach(reason: .pageTeardown)
        }
    }

    private var isRecoveringFromWebProcessDeath = false {
        didSet {
            if !isRecoveringFromWebProcessDeath { recoveryBackstop?.cancel() }
        }
    }

    @ObservationIgnored private var recoveryBackstop: Task<Void, Never>?

    /// Whether the desktop window existed and was closed, which separates
    /// "rebuild the page" from "the UI is still booting".
    private var desktopWasClosed = false

    /// Whether this desktop window has been routed; until then it renders
    /// nothing.
    var hasRoutedDesktop = false

    /// Whether a route is being retried, so a second ask does not race it.
    var isRoutingDesktop = false

    func storeBrowserViewStatuses() -> [BrowserViewChild.Status] {
        desktop?.browserViewStatuses ?? []
    }

    // MARK: - Popup adoption

    func windowDidAdopt(_ window: SteamWindow) {
        EventLog.shared.log(.window, "popup adopted: \(window.name) as \(window.role)")
        refreshLoginWindowState()
        defer { logWindowInventory("adopting \(window.name)") }
        // A popup adopted while the overlay is up rides with the overlay. The
        // overlay's UI instance also restores the panels open when it last
        // closed, as soon as a game starts with the overlay down; those
        // would sit over the game as ordinary windows, so they are closed.
        let fromOverlayInstance = SteamWindowRole.instanceUID(ofPopupNamed: window.name) != 0
        let isOverlayFurniture = window.role != .desktop && window.role != .context
            && window.role != .gameOverlay && window.role != .toast && window.role != .menu
        if overlayActive, isOverlayFurniture {
            overlayChildren.append(window)
        } else if fromOverlayInstance, isOverlayFurniture {
            EventLog.shared.log(
                .window, "closed \(window.name): opened by the game overlay while it is down",
            )
            window.close()
            return
        }
        // The root menus are created after the desktop window, so every
        // adoption re-reads the strip.
        menuMirror?.refresh()
        if window.role == .login {
            window.webView.evaluateJavaScript(SteamDesktopChrome.popupScript)
        } else if window.role.hasPopupChrome {
            window.webView.evaluateJavaScript(SteamDesktopChrome.popupChromeScript)
        }
        if Preferences.userStyles {
            window.webView.evaluateJavaScript(SteamUserCSS.script(css: userStylesheet))
        }
        guard window.role == .desktop else { return }
        desktop = window
        desktopWasClosed = false
        hasRoutedDesktop = false
        updateEnergyPreference()
        isRecoveringFromWebProcessDeath = false
        status = "Steam is ready"
        PerfProbe.poi.emitEvent("DesktopAdopted")
        EventLog.shared.log(.window, "desktop window adopted — Steam is ready")
        window.webView.evaluateJavaScript(SteamDesktopChrome.script)
        applyCompatibilityStrip()
        applyNativeBuilds()
        Task(name: "Register game-action events") {
            let result = await evaluateInContext(Self.gameActionScript)
            EventLog.shared.log(.client, "game-action events: \(result ?? "no answer")")
        }
        installContextScripts()
        refreshRecentGamesWhenLoaded()
        if desktopShowIsPending {
            desktopShowIsPending = false
            routeDesktop()
            if !pendingShowActivates { window.staysBehindUntil = .now + Self.bootingPageAsksForFocus }
            window.show(activating: pendingShowActivates)
            pendingShowActivates = true
            reopenInstallWizardIfNeeded()
        }
    }

    /// The press monitor the menu dismissal guard installs.
    @ObservationIgnored var menuDismissalMonitor: Any?

    func windowDidClose(_ window: SteamWindow, reason: SteamWindow.DetachReason) {
        popups.removeValue(forKey: ObjectIdentifier(window.webView))
        refreshLoginWindowState()
        defer { logWindowInventory("closing \(window.name)") }
        // Holding a closed overlay child would keep its web view alive past
        // the teardown that tells Steam the popup is gone.
        overlayChildren.removeAll { $0 === window }
        // Steam learns a popup is gone from its document's `unload`, which
        // WebKit ties to page teardown. Only a popup that went on its own is
        // owed it: during a teardown it runs `CPopup.OnClose`, which for the
        // login window quits Steam. Menus are reopened by name and reaped
        // with the desktop's page.
        if reason == .steamClosedIt, !isTearingDownPage,
           window !== desktop, window.role != .menu, window.role != .context {
            notifyPopupUnloaded(named: window.name)
            repairStuckModalOverlay()
            // Closing Settings can rewrite the strip's labels.
            menuMirror?.refresh()
        }
        guard window === desktop else { return }
        desktop = nil
        desktopWasClosed = true
        desktopShowIsPending = false
        // Steam keeps a dozen hidden context-menu popups per desktop window
        // and reaps them only when it tears the window down itself; without
        // this, every close/open cycle strands another dozen.
        for popup in popups.values where popup.role == .menu {
            popup.detach(reason: .pageTeardown)
        }
        menuMirror?.refresh()
        status = "Steam window closed"
        EventLog.shared.log(.window, "desktop window closed — its page is gone")
        ActivationPolicy.recedeIfLastWindow(closing: nil)
    }

    func setStatus(_ value: String) {
        status = value
    }
}
