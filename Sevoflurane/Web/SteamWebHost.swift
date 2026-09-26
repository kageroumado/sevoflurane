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

    /// Whether the page holds Steam's login window — the signed-out state in
    /// which Steam's services legitimately never initialize until the user
    /// acts. The supervisor holds its recovery ladder on this, and every
    /// reload path refuses while it is true: a reload detaches the popup, and
    /// Steam reads its document unloading as the user closing the sign-in
    /// window, which quits.
    ///
    /// The popup existing is the whole test. Whether it is on screen is a
    /// question about window ordering, and a window this app is deliberately
    /// holding back is still a session waiting on a human.
    var isAwaitingSignIn: Bool {
        Self.isAwaitingSignIn(popupRoles: popups.values.map(\.role))
    }

    /// Whether a page holding these popups is waiting on a sign-in. Visibility
    /// is not a parameter: a login window this app is deliberately keeping off
    /// screen is still a session waiting on a human, and keying on visibility
    /// is what let a stuck stop flag switch the whole guard off.
    static func isAwaitingSignIn(popupRoles: some Sequence<SteamWindowRole>) -> Bool {
        popupRoles.contains(.login)
    }

    /// ``isAwaitingSignIn``, observable: the popup table is not, and the setup
    /// assistant's finish button waits on this to name the window it opens.
    /// Refreshed wherever a popup is adopted or closes.
    private(set) var hasLoginWindow = false

    func refreshLoginWindowState() {
        let awaiting = isAwaitingSignIn
        if hasLoginWindow != awaiting { hasLoginWindow = awaiting }
    }

    /// The login window itself, for the paths that must put it in front of
    /// the user rather than rebuild the page under it.
    var loginWindow: SteamWindow? {
        popups.values.first { $0.role == .login }
    }

    /// While true, a login window Steam asks to show stays built but off
    /// screen — the onboarding wizard is still up, and the wizard's finish
    /// button is the moment the user asked for a window.
    private(set) var isHoldingWindows = false

    /// Whether the user chose to use the app without signing in to Steam: its
    /// own Windows programs run from Quick Launch, and Steam stays signed out
    /// in the background. The login window Steam asks to show stays built and
    /// off screen, as under the setup hold, until the user asks for Steam —
    /// which is choosing to sign in after all, and clears this.
    var signInIsSkipped = Preferences.app.bool(forKey: SteamWebHost.signInSkippedKey) {
        didSet { Preferences.app.set(signInIsSkipped, forKey: Self.signInSkippedKey) }
    }

    private static let signInSkippedKey = "steamSignInSkipped"

    /// Whether a login window Steam asks to show stays off screen.
    var defersLoginWindow: Bool {
        isHoldingWindows || signInIsSkipped
    }

    /// Set while the supervisor brings the client down (a quit, a stop, a
    /// restart). The client asks for its windows again on the way out, and
    /// `SteamWindow.show` answers those requests with nothing.
    private(set) var clientIsStopping = false

    /// Runs a stop with the client marked as stopping. The mark is a scoped
    /// token rather than a flag two subsystems poke, so it clears when the
    /// stop ends, whether or not the client ever became healthy — every
    /// signed-out boot is such a stop, and a mark left set refuses every
    /// login window `show()` asks for.
    func duringClientStop<T>(_ body: () async -> T) async -> T {
        beginClientStop()
        defer { endClientStop() }
        return await body()
    }

    /// The same mark, opened and closed by the daemon across the link — a stop
    /// runs in the daemon's process, so the scope cannot be a Swift one.
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

    /// Every installed game, in the order ``LibraryIndex`` files them: the
    /// popover's index under the recent ones.
    private(set) var libraryGames: [RecentGame] = []

    var benchmarkRunning = false
    let mainQueueLatency = MainQueueLatencyProbe()
    private var evaluationSequence = 0
    private var evaluationPending: [Int: CheckedContinuation<String?, Never>] = [:]
    private var evaluationTimeouts: [Int: Task<Void, Never>] = [:]

    nonisolated struct RecentGame: Identifiable, Decodable, Equatable, Sendable {
        let id: Int
        let name: String
        /// What Steam's library shows under the name, by the client's own numbering.
        var displayStatus: Int?
        /// The name Steam's own library sorts by (`sort_as`): no leading
        /// article, a romanized title for one written in another script.
        var sortAs: String?

        /// What the index files the game under.
        var sortName: String {
            guard let sortAs, !sortAs.isEmpty else { return name }
            return sortAs
        }

        /// Synchronizing (8): Steam Cloud has the game's saves in hand.
        var isInCloudSync: Bool { displayStatus == 8 }

        /// Capsule art, served by the bridge (local cache, CDN fallback).
        var artURL: URL {
            URL(string: "http://127.0.0.1:\(BridgePorts.art)/art/\(id).jpg")!
        }
    }

    /// When each game was first seen at Synchronizing.
    @ObservationIgnored private var cloudSyncSince: [Int: Date] = [:]

    /// The games the client has held at Synchronizing for longer than a sync takes. A game
    /// force-ended during its Steam Cloud sync stays there, and the client accepts and drops
    /// every launch of it until it restarts.
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

    /// Asks the page for the installed games: the five most recently played,
    /// and every one of them for the index. One evaluation answers both, so
    /// the two lists never describe different moments of the library.
    func refreshRecentGames() {
        Task(name: "Refresh recent games") {
            guard let raw = await evaluateInContext(Self.installedGamesScript),
                  let data = raw.data(using: .utf8),
                  let answer = try? JSONDecoder().decode(InstalledGames.self, from: data)
            else { return }
            noteCloudSyncs(in: answer.library, at: .now)
            if answer.recent != recentGames { recentGames = answer.recent }
            let library = LibraryIndex.sorted(answer.library)
            if library != libraryGames { libraryGames = library }
        }
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

    /// Launches a game exactly as Steam's tray menu does.
    func launchGame(_ game: RecentGame) {
        launchGame(appID: game.id)
    }

    /// The same call by app id, for the daemon: it decides whether a launch
    /// needs the client restarted first, and the launch itself comes back here
    /// because it is a line of JavaScript in the page.
    ///
    /// `forgettingChoice` clears the launch option Steam remembers for the app
    /// first, so its `ShowLaunchOption` request is asked rather than answered
    /// from memory: what an answer given ahead of time (``launchOptionAnswers``)
    /// needs, since Steam's own UI answers from memory before this app can.
    func launchGame(appID: Int, forgettingChoice: Bool = false) {
        context?.webView.evaluateJavaScript(
            forgettingChoice
                ? LaunchOptions.forgetAndRunScript(appID: appID)
                : "SteamClient.Apps.RunGame(String(\(appID)), '', -1, 100)",
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

    /// What a sweep of the client's popups leaves alone right now: the popup
    /// named after the game a launch is in flight for, and any other
    /// desktop-UI popup the role table cannot name, since either may be the
    /// dialog the launch is waiting on. While this app's own alert is asking
    /// the question, the client's copy of it is redundant and is not spared.
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

    /// What the host has seen of the user, for telling a chat window Steam
    /// opened for an incoming message from one it opened for a click.
    @ObservationIgnored var chatPolicy = UnaskedChatPolicy(startingAt: .now)

    /// The unread count Steam posts to the client, tapped on its way through
    /// the shim.
    func noteUnreadChats(_ count: Int) {
        let clamped = max(0, count)
        guard clamped != unreadChats else { return }
        unreadChats = clamped
        EventLog.shared.log(.client, "unread conversations: \(clamped)")
    }

    /// Installs the scripts the context page needs standing: the notification
    /// subscription, and the refusal of the chat window Steam opens for an
    /// incoming message.
    ///
    /// Both reach for a global the bundle assigns partway through boot, and
    /// Steam sends no "the UI is ready" signal, so each is retried until it
    /// answers with one of the outcomes that means it is in place — the same
    /// gap ``SteamMenuMirror`` retries across. The bottled client runs a
    /// second copy of the friends UI, which opens a CEF chat window of its
    /// own, so the refusal goes to that one too.
    private func installContextScripts() {
        install(
            Self.notificationScript,
            describedAs: "Steam notifications",
            settledAt: ["registered", "already registered"],
        )
        install(
            Self.overlayScript,
            describedAs: "Steam overlay activation",
            settledAt: ["registered", "already registered"],
        )
        install(
            SteamChatAutoOpen.refusalScript,
            describedAs: "unasked chat windows",
            settledAt: SteamChatAutoOpen.settled,
        )
        install(
            SteamMessageSound.refusalScript,
            describedAs: "Steam's own message sound",
            settledAt: SteamMessageSound.settled,
        )
        installInClient(
            SteamChatAutoOpen.refusalScript,
            describedAs: "unasked chat windows",
            settledAt: SteamChatAutoOpen.settled,
        )
        installInClient(
            SteamMessageSound.refusalScript,
            describedAs: "Steam's own message sound",
            settledAt: SteamMessageSound.settled,
        )
    }

    private func installInClient(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what) in the client") {
            let result = await ClientLifecycle.installInClientUI(script, settledAt: outcomes)
            EventLog.shared.log(.client, "\(what) in the client: \(result)")
        }
    }

    private func install(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what)") {
            for _ in 1 ... 10 {
                if let result = await evaluateInContext(script), outcomes.contains(result) {
                    EventLog.shared.log(.app, "\(what): \(result)")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            EventLog.shared.log(.app, "\(what): Steam's own globals never appeared")
        }
    }

    // MARK: - Launch status

    /// A launch in flight, told by the client's own game-action events.
    struct GameLaunch: Equatable {
        let appID: Int
        var detail: String
        /// The client's id for this game action, which its `ShowLaunchOption`
        /// request is answered against.
        var actionID: Int?
    }

    private(set) var activeLaunch: GameLaunch?
    @ObservationIgnored private var launchClear: Task<Void, Never>?

    #if DEBUG
        /// A host with a library and no client behind it, for the gallery.
        /// Nothing here starts a page: the web views exist only after
        /// ``bootstrap()``, which the gallery never calls.
        /// `library` is every installed game; left out, it is the recent
        /// ones, a library small enough that the popover shows no index.
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

    /// A launch has begun for this app id, on any path (library, popover,
    /// `steam://run`, the CLI): the client's own game-action event, so it
    /// fires even for a launch the bridge never saw.
    var onGameLaunchStart: ((Int) -> Void)?

    /// An app started or stopped running, told by the client itself
    /// (`GameSessions.RegisterForAppLifetimeNotifications`). The stop edge is
    /// what closes a run record.
    var onGameRunningChanged: ((_ appID: Int, _ running: Bool) -> Void)?

    /// The client showed an error for a game action — it refused or abandoned
    /// the launch rather than the game exiting on its own.
    var onGameActionError: ((_ appID: Int, _ detail: String) -> Void)?

    /// The launch task the log last carried, as `appid:task`.
    var lastLoggedLaunchTask: String?

    /// The expected refusals this page has already logged, so each is said
    /// once per page load.
    private var loggedRefusals: Set<String> = []

    /// Logs what the page's error guard reported: an error as it arrived, a
    /// refusal every session produces once and in plain words.
    func notePageError(_ detail: String) {
        switch PageErrorTriage.verdict(for: detail) {
        case .error:
            EventLog.shared.log(.window, "page error — \(detail)")
        case let .expected(sentence):
            if loggedRefusals.insert(sentence).inserted {
                EventLog.shared.log(.page, "expected: \(sentence)")
            }
        }
    }

    // Overlay presence. It is shown only while the overlay is active *and* the
    // game (or this app, once the overlay has taken key) is frontmost, so it
    // rides just above the game and vanishes the moment another app comes
    // forward — never a full-screen window sitting over everything.
    @ObservationIgnored var overlayActive = false
    @ObservationIgnored var overlayGame: WineWindowWatch.GameWindow?
    @ObservationIgnored var overlayAppID = ""
    /// The latest pass of the energy preference mirror, which the next one
    /// waits behind.
    @ObservationIgnored var energyUpdate: Task<Void, Never>?
    @ObservationIgnored var overlayFrontObserver: (any NSObjectProtocol)?
    @ObservationIgnored var overlayKeyMonitor: Any?

    /// The popups Steam opened while the overlay was up (its Settings, friends,
    /// dialogs). The overlay owns them: they are ordered in and out with it and
    /// dismissed when it closes, so none is left floating above the game.
    @ObservationIgnored var overlayChildren: [SteamWindow] = []

    /// The game's first window is up (``GameLaunchWatch``) — story over.
    func gameWindowDidAppear() {
        guard activeLaunch != nil else { return }
        launchClear?.cancel()
        activeLaunch = nil
    }

    /// A Quick Launch program was pressed. The client never hears of these,
    /// so the app tells their launch story itself, in the same three beats a
    /// Steam launch gets: the row's status line at once, …
    func beginProgramLaunch(appID: Int) {
        setLaunch(GameLaunch(appID: appID, detail: String(localized: "Starting…")), clearAfter: 180)
    }

    /// … then, once the helper has spawned it, the window watch and the run
    /// record, which ``onGameLaunchStart`` opens for every launch, …
    func programDidStart(appID: Int) {
        setLaunch(
            GameLaunch(appID: appID, detail: String(localized: "Waiting for its window…")), clearAfter: 180,
        )
        onGameLaunchStart?(appID)
    }

    /// … or, when the helper started nothing, the status line cleared again.
    func endProgramLaunch(appID: Int) {
        guard activeLaunch?.appID == appID else { return }
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

    // MARK: - Boot

    /// Starts Steam's UI at launch rather than on first window open, mirroring
    /// the client itself: by the time the user asks for a window, the UI is
    /// already running and the window can be handed over immediately.
    func bootstrap() {
        guard context == nil else { return }
        installMenuDismissalGuard()
        installEnergyPreferenceMirror()
        createContextPage()
    }

    /// Tears the context page down to nothing and boots a fresh one: a new web
    /// view, a new web content process, new delegates. The rung above
    /// `reload()`, for the page a reload cannot bring back: a web view whose
    /// content process is gone or wedged loads nothing, while WebKit's
    /// networking process keeps its socket to the bridge open — so the bridge
    /// goes on sending every eval into that socket and every one times out.
    func rebuildContextPage() {
        EventLog.shared.log(
            .page, "rebuilding the UI page from scratch (\(popups.count) popups detached)",
        )
        detachPopups(reason: .pageTeardown)
        desktop = nil
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
        // that lives in a window. A window with no size and no opacity at the
        // origin schedules it exactly as an on-screen one does — measured:
        // the page keeps `document.visibilityState == "visible"` and its
        // animation frames at 60 Hz, because occlusion detection is off for
        // this view — and it is not a phantom in `/windows`, in the window
        // server's lists, or on a display the user just plugged in. The web
        // view keeps its own 1280×800 frame inside it, so the page's viewport
        // is the size Steam's UI expects rather than nothing.
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
        webView.load(URLRequest(url: Self.uiURL))
    }

    func reload() {
        EventLog.shared.log(.page, "reloading the UI page (\(popups.count) popups detached)")
        detachPopups(reason: .pageTeardown)
        desktop = nil
        status = "reloading"
        loggedRefusals = []
        context?.webView.load(URLRequest(url: Self.uiURL))
    }

    /// Whether a detach loop over every popup is running. The backstop under
    /// ``SteamWindow/DetachReason``: a detach that reaches
    /// ``windowDidClose(_:reason:)`` by some other route while the page under
    /// it is going still says nothing to Steam.
    private var isTearingDownPage = false

    /// Drops every adopted popup, telling each why. One writer for all three
    /// teardowns, so none of them can forget the guard.
    private func detachPopups(reason: SteamWindow.DetachReason) {
        isTearingDownPage = true
        defer { isTearingDownPage = false }
        for popup in popups.values {
            popup.detach(reason: reason)
        }
        popups.removeAll()
    }

    /// Clears the windows a dead client left on screen — its library is frozen
    /// and dimmed once nothing is behind it, and leaving it up for the length
    /// of a restart is the "stuck, dimmed Steam window" the user sees. The
    /// fresh client adopts its own windows when it boots; the context page
    /// stays, so this is lighter than a full reload.
    func dismissWindows(reason: SteamWindow.DetachReason = .pageTeardown) {
        guard desktop != nil || !popups.isEmpty else { return }
        detachPopups(reason: reason)
        desktop = nil
        desktopWasClosed = true
        status = "reconnecting"
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
        if let loginWindow, isAwaitingSignIn {
            // Signed out, the window the user is asking for is the login
            // popup. The desktop window can exist beside it, but a signed-out
            // client never boots its stores, so it would show empty and fail
            // to route; and a reload would detach the popup, which Steam reads
            // as the user closing its sign-in window, and quits.
            EventLog.shared.log(
                .window, "asked for Steam while signed out — bringing the login window forward",
            )
            signInIsSkipped = false
            loginWindow.show(activating: true)
            return
        }
        if let desktop {
            // The window exists from the moment Steam's UI boots, but on no
            // route — a `-silent` client is the same until its tray item is
            // clicked. Routing it is what fills it, and it happens the first
            // time someone actually asks for the window rather than at
            // launch: a menu-bar app that puts a window on screen at login
            // is not a menu-bar app.
            if !hasRoutedDesktop {
                routeDesktop()
            }
            desktop.show(activating: true)
            return
        }
        // Come forward now, while the user's click is still the reason for it.
        // The rebuilt window does not exist for another couple of seconds, and
        // by then cooperative activation no longer sees an event to attribute
        // the request to: it declines, and the window arrives behind whatever
        // was frontmost with its traffic lights gray.
        ActivationPolicy.becomeRegular(forAWindowWithin: ActivationPolicy.graceForAPromisedWindow)
        NSApp.activate()
        // The window the user asked for does not exist yet: a reload boots
        // the UI and Steam re-creates its desktop window hidden, on the
        // route it had. Nothing else would ever show it, so the request is
        // held until the adoption it is waiting for.
        desktopShowIsPending = true
        if desktopWasClosed {
            reload()
        } else {
            routeDesktop()
        }
    }

    /// Whether a ``showSteam`` found no desktop window and is waiting for the
    /// one the page is building. Cleared by the adoption that answers it, and
    /// by a close, which is a newer statement of what the user wants.
    private var desktopShowIsPending = false

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
            window?.detach(reason: .pageTeardown)
        }
    }

    private var isRecoveringFromWebProcessDeath = false

    /// Whether the desktop window existed and the user closed it — the state
    /// that separates "rebuild the page" from "the UI is still booting".
    private var desktopWasClosed = false

    /// Whether this desktop window has been sent to a route yet. A freshly
    /// adopted one renders nothing until it is.
    private var hasRoutedDesktop = false

    /// Whether a route is being retried, so a second ask joins the first
    /// rather than racing it onto the same window.
    private var isRoutingDesktop = false

    /// The context boots its window on no route at all, the same way a
    /// `-silent` client does until its tray item is clicked. The route runs
    /// through Steam's own navigator in this page — `ExecuteSteamURL` would
    /// navigate the window the *bottle's* client owns instead.
    ///
    /// Answers whether the route was taken. It is refused while the page is
    /// still booting: `Home()` runs `ExitSearch → ResetSearch → SetIsCollapsed`
    /// against the collection store, which the navigator's own existence says
    /// nothing about.
    func openLibrary() async -> Bool {
        await evaluateInContext("""
        (function () {
          if (!window.__sevoIsReady || !__sevoIsReady()) return "false";
          var window_ = window.SteamUIStore && SteamUIStore.WindowStore
            && SteamUIStore.WindowStore.MainWindowInstance;
          var nav = window_ && window_.Navigator;
          if (!nav || typeof nav.Home !== "function") return "false";
          nav.Home();
          return "true";
        })()
        """) == "true"
    }

    /// How long a route waits for the page to be ready, and how often it
    /// asks — the bounded poll ``repairBlankDesktop`` runs on, at the pace a
    /// user notices a window that is still black.
    private enum Routing {
        static let attempts = 40
        static let interval: Duration = .milliseconds(250)
    }

    /// Sends the desktop to the library, retrying while the page's stores
    /// are still arriving.
    func routeDesktop() {
        Task(name: "Route the desktop to the library") { [weak self] in
            await self?.routeDesktopWhenReady()
        }
    }

    /// The retry itself. A page that never becomes ready says so once: the
    /// window stays on no route, which ``repairBlankDesktop`` is the backstop
    /// for.
    private func routeDesktopWhenReady() async {
        guard !isRoutingDesktop else { return }
        isRoutingDesktop = true
        defer { isRoutingDesktop = false }
        for _ in 0 ..< Routing.attempts {
            if await openLibrary() {
                hasRoutedDesktop = true
                return
            }
            try? await Task.sleep(for: Routing.interval)
        }
        EventLog.shared.log(
            .window, "Steam's stores never finished booting — the desktop is on no route",
        )
    }

    /// A window is about to reach the screen.
    ///
    /// The desktop is the one that needs a word first. Steam boots its window
    /// on no route, so one that arrives on screen without having been
    /// navigated is chrome over black: the nav bar and the footer render and
    /// everything between them is empty. ``showSteam`` routes the window it
    /// opens; a window Steam puts up itself reaches the screen through here
    /// instead, which is what an app relaunched onto a live client, or a
    /// client that came back on its own, gives the user.
    func noteWindowWillShow(_ window: SteamWindow) {
        guard window.role == .desktop, !clientIsStopping else { return }
        guard hasRoutedDesktop else {
            routeDesktop()
            return
        }
        repairBlankDesktop()
    }

    /// Sends a desktop that is showing no route back to the library.
    ///
    /// The blank state reads the same from the page whatever put it there:
    /// the element under the middle of the window is the container the route
    /// would render into, filling the space between the header and the
    /// footer, because nothing is painted over it. The store reads the same
    /// way, since its content is a native child view rather than page
    /// content, so a visible BrowserView stands the check down — and because
    /// one that is still arriving would be missed, the reading has to hold
    /// across two samples a second apart before anything moves.
    func repairBlankDesktop() {
        Task(name: "Repair a blank desktop") { [weak self] in
            for _ in 0 ..< 2 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let desktop, desktop.isWindowVisible,
                      !desktop.browserViewStatuses.contains(where: \.visible),
                      await evaluateInContext(
                          Self.blankDesktopScript(desktop: desktop.name),
                      ) == "blank"
                else { return }
            }
            guard let self else { return }
            EventLog.shared.log(
                .window, "the desktop was showing no route — sent it back to the library",
            )
            await routeDesktopWhenReady()
        }
    }

    private static func blankDesktopScript(desktop name: String) -> String {
        """
        (function () {
          try {
            var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
            var entry = popups && popups.get(\(JSLiteral.string(name)));
            var win = entry && entry.m_popup;
            if (!win || win.closed) return "";
            var el = win.document.elementFromPoint(
              Math.round(win.innerWidth / 2), Math.round(win.innerHeight / 2));
            if (!el) return "";
            var rect = el.getBoundingClientRect();
            var fillsTheContentArea = rect.width >= win.innerWidth * 0.9
              && rect.height >= win.innerHeight * 0.6;
            return fillsTheContentArea ? "blank" : "";
          } catch (e) {
            return "error: " + e;
          }
        })()
        """
    }

    func storeBrowserViewStatuses() -> [BrowserViewChild.Status] {
        desktop?.browserViewStatuses ?? []
    }

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
    func evaluateInWebView(
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
    ///
    /// A page that is still booting answers `-1`: the URL is queued on the
    /// readiness promise and will run in this process, so the fallback that
    /// would raise a Wine window stays down.
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

    func windowDidAdopt(_ window: SteamWindow) {
        // The name is what classifies a popup, so an unexpected window on
        // screen can be traced to the name Steam gave it.
        EventLog.shared.log(.window, "popup adopted: \(window.name) as \(window.role)")
        refreshLoginWindowState()
        defer { logWindowInventory("adopting \(window.name)") }
        // A popup adopted while the overlay is up belongs to it (its Settings,
        // a dialog): track it so it is ordered in and out with the overlay and
        // dismissed when it closes, rather than left floating above the game.
        // The overlay's own UI instance also restores whatever panels were
        // open when it last closed — the friends list, a game overview — the
        // moment a game starts, with the overlay still down. Those would come
        // up as ordinary windows over the game, so they are closed instead:
        // the overlay starts every session with nothing open.
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
        // Every adoption is a chance the root menus now exist — they are
        // created after the desktop window, so anchoring on the desktop alone
        // reads an empty strip. Re-reading an unchanged strip is a no-op.
        menuMirror?.refresh()
        if window.role == .login {
            window.webView.evaluateJavaScript(SteamDesktopChrome.popupScript)
        } else if window.role.hasPopupChrome {
            window.webView.evaluateJavaScript(SteamDesktopChrome.popupChromeScript)
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
        // Steam draws a Windows title bar because under CEF it owns a
        // borderless OS window. Hosted here its buttons duplicate the traffic
        // lights and its strip has nowhere for them to sit.
        window.webView.evaluateJavaScript(SteamDesktopChrome.script)
        // The Mac compatibility strip on game pages, in the slot Steam's own
        // Deck strip leaves empty on a desktop client.
        applyCompatibilityStrip()
        Task(name: "Register game-action events") {
            let result = await evaluateInContext(Self.gameActionScript)
            EventLog.shared.log(.client, "game-action events: \(result ?? "no answer")")
        }
        installContextScripts()
        refreshRecentGames()
        // The user asked for the window before it existed; this is it.
        if desktopShowIsPending {
            desktopShowIsPending = false
            routeDesktop()
            window.show(activating: true)
        }
    }

    /// The press monitor the menu dismissal guard installs.
    @ObservationIgnored var menuDismissalMonitor: Any?

    func windowDidClose(_ window: SteamWindow, reason: SteamWindow.DetachReason) {
        popups.removeValue(forKey: ObjectIdentifier(window.webView))
        refreshLoginWindowState()
        defer { logWindowInventory("closing \(window.name)") }
        // A window the overlay adopted is held until the overlay dismisses, so
        // that it rides in and out with it. Once it has closed there is
        // nothing left to order, and holding it keeps its web view alive past
        // the page teardown that tells Steam the popup is gone.
        overlayChildren.removeAll { $0 === window }
        // Steam learns a popup is gone from its document's `unload`, which
        // WebKit ties to the page's teardown rather than to the window
        // closing. Only a popup that went on its own is owed that word: a
        // teardown takes the listeners with it, and telling Steam anyway runs
        // `CPopup.OnClose`, which for the login window is the user closing it
        // — and closing it quits Steam. Menus are left out: Steam keeps one
        // per window and reopens it by name, and the app reaps them wholesale
        // when the desktop's page goes.
        if reason == .steamClosedIt, !isTearingDownPage,
           window !== desktop, window.role != .menu, window.role != .context {
            notifyPopupUnloaded(named: window.name)
            repairStuckModalOverlay()
            // Settings is one of these popups, and a language or a friends-list
            // preference rewrites the strip's labels as it closes.
            menuMirror?.refresh()
        }
        guard window === desktop else { return }
        desktop = nil
        desktopWasClosed = true
        desktopShowIsPending = false
        // Steam's context menus are per-window popups it creates lazily and
        // then keeps: a dozen hidden web views accumulate behind one desktop
        // window, and closing that window from our side leaves them orphaned
        // (Steam only reaps them when it tears the window down itself). They
        // belong to the page that just went, so they go with it — otherwise
        // every close/open cycle strands another dozen.
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
