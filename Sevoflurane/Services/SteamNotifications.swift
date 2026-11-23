import AppKit
import Observation
import UserNotifications

/// One notification Steam produced, as the context page reports it.
///
/// The page deserializes Steam's per-type protobuf body and resolves account
/// and app ids to names, so what arrives here is already names; the words are
/// written on this side.
struct SteamNotification: Decodable, Equatable, Sendable {
    /// Steam's `ENotificationType`, 1…64; see ``SteamNotifications/Presentation``.
    var kind: Int
    /// Steam's `ENotificationSource`: 1 is the client, 2 the servers, whose
    /// JSON bodies only Steam's web component renders.
    var source: Int
    var id: String
    /// The sender's persona for a message, the group's name for a group chat.
    var title: String
    var body: String
    /// The sender's avatar, on Steam's CDN.
    var icon: String
    var steamID: String
    /// The 32-bit account id — what Steam's own chat calls take.
    var accountID: String
    var appID: String
    var gameName: String
    /// Steam's own sound setting for this notification (the per-friend or
    /// chat-room setting). Absent from an older page's payload: silent.
    var playsSound: Bool?

    private enum CodingKeys: String, CodingKey {
        case kind
        case source
        case id
        case title
        case body
        case icon
        case steamID = "steamid"
        case accountID = "accountid"
        case appID = "appid"
        case gameName
        case playsSound = "sound"
    }
}

/// Steam's notifications, re-posted as the Mac's.
///
/// ``SteamWindowRole/toast`` keeps Steam's toast popup off screen while its
/// page runs, and this posts a Mac notification in its place. The page
/// subscribes to `NotificationStore.CurrentToastSubscribableValue`, so exactly
/// the toasts Steam would show arrive, its settings applied.
@MainActor
@Observable
final class SteamNotifications {
    /// What macOS says about our permission to post.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Whether a notification was dropped before permission was asked; the
    /// popover's permission card shows while true.
    private(set) var hasUnaskedNotifications = false

    /// Where a notification's click goes; weak, since the host owns this.
    @ObservationIgnored weak var host: SteamWebHost?

    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private var delegate: Forwarder?
    /// Rereads the permission whenever the app comes forward, which is how a
    /// person returns from changing it in System Settings.
    @ObservationIgnored private var activationObserver: (any NSObjectProtocol)?

    init() {
        // `UNUserNotificationCenter.current()` traps in a process with no
        // bundle identifier — the gallery and the unit tests both run as one.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    #if DEBUG
        /// A relay in a fixed permission state with no notification center, for the gallery.
        static func preview(
            authorization: UNAuthorizationStatus = .authorized,
            unasked: Bool = false,
        ) -> SteamNotifications {
            let relay = SteamNotifications(withoutCenter: ())
            relay.authorization = authorization
            relay.hasUnaskedNotifications = unasked
            return relay
        }

        private init(withoutCenter _: Void) {
            center = nil
        }
    #endif

    // MARK: - Authorization

    /// Installs the delegate and reads the permission without prompting. Must
    /// run before launch finishes, or a click that woke the app is lost.
    func start() {
        guard let center else { return }
        let forwarder = Forwarder(relay: self)
        delegate = forwarder
        center.delegate = forwarder
        center.setNotificationCategories([Self.fixesCategory, Self.sessionCategory])
        Task(name: "Read notification authorization") { await refreshAuthorization() }
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                Task(name: "Reread notification authorization") { await self?.refreshAuthorization() }
            }
        }
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Raises the system permission alert; call only from a user's click.
    func requestAuthorization() async {
        guard let center else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            EventLog.shared.log(.app, "notification permission request failed: \(error)")
        }
        await refreshAuthorization()
        hasUnaskedNotifications = false
        EventLog.shared.log(.app, "notification permission is now \(authorization.name)")
    }

    /// Where the user goes once they have said no: macOS will not ask twice.
    func openSystemSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension",
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Posting

    /// Posts one of Steam's notifications, or logs why not.
    func post(_ notification: SteamNotification) {
        guard notification.source == Self.clientSource else {
            EventLog.shared.log(
                .app,
                "notification \(notification.id): server-sourced type "
                    + "\(notification.kind) — left to Steam's own surfaces",
            )
            return
        }
        guard let presentation = Presentation(notification) else {
            EventLog.shared.log(
                .app,
                "notification \(notification.id): type \(notification.kind) has no "
                    + "presentation here — dropped rather than posted unnamed",
            )
            return
        }
        switch authorization {
        case .notDetermined:
            hasUnaskedNotifications = true
            EventLog.shared.log(
                .app,
                "notification \(notification.id) held: macOS has not been asked yet "
                    + "— the popover offers the switch",
            )
        case .denied:
            EventLog.shared.log(
                .app, "notification \(notification.id) dropped: notifications are off for this app",
            )
        default:
            Task(name: "Post notification \(notification.id)") {
                await deliver(presentation, for: notification)
            }
        }
    }

    /// Steam's `ENotificationSource` for a notification the client raised.
    private static let clientSource = 1

    private func deliver(_ presentation: Presentation, for notification: SteamNotification) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = presentation.title
        content.body = presentation.body
        // ``SteamMessageSound`` refuses Steam's chime for messages, so the
        // sound is the notification's, under the system's volume and Do Not
        // Disturb, decided by Steam's own sound setting.
        content.sound = presentation.isSounded ? .default : nil
        content.userInfo = presentation.route.userInfo
        content.threadIdentifier = presentation.route.threadIdentifier
        if let attachment = await Self.attachment(for: notification) {
            content.attachments = [attachment]
        }
        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: notification.id, content: content, trigger: nil,
                ),
            )
        } catch {
            EventLog.shared.log(.app, "could not post notification \(notification.id): \(error)")
            return
        }
        if presentation.isTransient {
            // UserNotifications has no transient flag; withdrawn after the banner.
            try? await Task.sleep(for: .seconds(8))
            center.removeDeliveredNotifications(withIdentifiers: [notification.id])
        }
    }

    private static let maximumAvatarBytes = 4 << 20
    /// The banner waits for the avatar, so a slow image host costs seconds,
    /// never the minute a default request waits.
    private static let avatarTimeout: TimeInterval = 5

    nonisolated static func isAvatarHost(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return ["steamstatic.com", "steamcdn-a.akamaihd.net", "steamusercontent.com"]
            .contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// The sender's avatar as a file, which `UserNotifications` moves into its own store.
    private static func attachment(for notification: SteamNotification) async
        -> UNNotificationAttachment? {
        // The address comes with the notification, a friend's message
        // included: only Steam's own image hosts are fetched, and only an
        // image's worth of bytes kept.
        guard let url = URL(string: notification.icon),
              url.scheme == "https", isAvatarHost(url.host()),
              let (data, _) = try? await URLSession.shared.data(
                  for: URLRequest(url: url, timeoutInterval: avatarTimeout),
              ),
              data.count <= maximumAvatarBytes else { return nil }
        let file = FileManager.default.temporaryDirectory
            .appending(path: "sevo-avatar-\(notification.id)-\(UUID().uuidString).jpg")
        guard (try? data.write(to: file)) != nil else { return nil }
        return try? UNNotificationAttachment(identifier: "", url: file)
    }

    // MARK: - The fix list

    /// The fix list's notification carries one action, Undo.
    private static let fixesCategory = UNNotificationCategory(
        identifier: "fixes",
        actions: [UNNotificationAction(identifier: undoAction, title: String(localized: "Undo"))],
        intentIdentifiers: [],
    )

    private static let undoAction = "undo"

    /// Says a game's first launch took the fix list's `settings`, with Undo;
    /// a click opens the game in Settings › Games.
    func postFixesApplied(appID: Int, name: String, settings: [String]) {
        guard let center, [.authorized, .provisional].contains(authorization) else {
            EventLog.shared.log(
                .app,
                "fixes: no notification for \(name) (notifications \(authorization.name)); "
                    + "Settings › Games offers the undo",
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = String(localized: "Set by known fixes: \(settings.joined(separator: ", "))")
        content.categoryIdentifier = Self.fixesCategory.identifier
        content.userInfo = Route.fixes(appID: appID).userInfo
        content.threadIdentifier = Route.fixes(appID: appID).threadIdentifier
        Task(name: "Post the fix list's notification for \(appID)") {
            do {
                try await center.add(
                    UNNotificationRequest(identifier: "fixes-\(appID)", content: content, trigger: nil),
                )
            } catch {
                EventLog.shared.log(.app, "could not post the fix list's notification for \(appID): \(error)")
            }
        }
    }

    /// A Dock tile's launch the helper declined; the popover has its own status line.
    func postLaunchDeclined(name: String, reason: String) {
        guard let center, [.authorized, .provisional].contains(authorization) else {
            EventLog.shared.log(.app, "Dock tile: no notification for \(name) (notifications \(authorization.name))")
            return
        }
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = reason
        Task(name: "Post the declined launch of \(name)") {
            do {
                try await center.add(
                    UNNotificationRequest(identifier: "launch-declined-\(name)", content: content, trigger: nil),
                )
            } catch {
                EventLog.shared.log(.app, "could not post the declined launch of \(name): \(error)")
            }
        }
    }

    /// Undoes what the fix list set on a game, from the notification's action.
    private func undoFixes(appID: Int) {
        Task.detached(name: "Undo the fix list for \(appID)") {
            guard FixLedger.undo(appID: appID) != nil else { return }
            EventLog.enqueue(.app, "fixes: app \(appID) put back from the notification")
        }
    }

    // MARK: - The Steam session

    /// The signed-out notification carries one action, Reconnect.
    private static let sessionCategory = UNNotificationCategory(
        identifier: "session",
        actions: [UNNotificationAction(identifier: reconnectAction, title: String(localized: "Reconnect"))],
        intentIdentifiers: [],
    )

    private static let reconnectAction = "reconnect"
    private static let sessionIdentifier = "signed-in-elsewhere"

    /// Says the bottle's Steam was signed out by another client, naming
    /// Steam for Mac when it was that.
    func postSignedInElsewhere(bySteamForMac: Bool) {
        guard let center, [.authorized, .provisional].contains(authorization) else {
            EventLog.shared.log(
                .app, "session: no notification (notifications \(authorization.name)); the menu bar offers Reconnect",
            )
            return
        }
        let content = UNMutableNotificationContent()
        content.title = String(localized: "Steam signed out here")
        content.body = bySteamForMac
            ? String(localized: "Your account signed in to Steam for Mac. Steam reconnects here when Steam for Mac quits.")
            : String(localized: "Your account signed in on another computer.")
        content.categoryIdentifier = Self.sessionCategory.identifier
        content.userInfo = Route.steam.userInfo
        Task(name: "Post the signed-out notification") {
            do {
                try await center.add(
                    UNNotificationRequest(identifier: Self.sessionIdentifier, content: content, trigger: nil),
                )
            } catch {
                EventLog.shared.log(.app, "could not post the signed-out notification: \(error)")
            }
        }
    }

    /// Takes the signed-out notification back once Steam is signed in again.
    func withdrawSignedInElsewhere() {
        center?.removeDeliveredNotifications(withIdentifiers: [Self.sessionIdentifier])
    }

    // MARK: - Clicks

    /// A notification's button, or the notification itself when `action`
    /// is the default one.
    func handleResponse(action: String, userInfo: [AnyHashable: Any]) {
        if action == Self.undoAction, case let .fixes(appID) = Route(userInfo: userInfo) {
            undoFixes(appID: appID)
        } else if action == Self.reconnectAction {
            (NSApp.delegate as? AppDelegate)?.steamSession.reconnect(because: "Reconnect in the notification")
        } else {
            handleClick(userInfo: userInfo)
        }
    }

    /// Opens what a clicked notification was about.
    func handleClick(userInfo: [AnyHashable: Any]) {
        switch Route(userInfo: userInfo) {
        case let .chat(accountID):
            host?.openChat(accountID: accountID)
        case .friends:
            host?.openFriends()
        case .steam:
            EventLog.shared.log(.window, "notification click routed to Steam — showing Steam")
            host?.showSteam()
        case let .fixes(appID):
            let name = GameConfig.game(appID).name ?? "App \(appID)"
            (NSApp.delegate as? AppDelegate)?.showGameSettings(id: appID, name: name)
        }
    }

    // MARK: - What a notification says, and where it goes

    /// Where clicking a notification takes the user.
    enum Route: Equatable {
        case chat(accountID: String)
        /// The friends list, for a conversation this app cannot address directly.
        case friends
        /// Steam's own window, for notifications about a game.
        case steam
        /// Settings › Games on one game.
        case fixes(appID: Int)

        var userInfo: [AnyHashable: Any] {
            switch self {
            case let .chat(accountID): ["open": "chat", "accountid": accountID]
            case .friends: ["open": "friends"]
            case .steam: ["open": "steam"]
            case let .fixes(appID): ["open": "fixes", "appid": appID]
            }
        }

        /// One Notification Center thread per conversation.
        var threadIdentifier: String {
            switch self {
            case let .chat(accountID): "chat-\(accountID)"
            case .friends: "friends"
            case .steam: "steam"
            case .fixes: "fixes"
            }
        }

        init(userInfo: [AnyHashable: Any]) {
            switch userInfo["open"] as? String {
            case "chat":
                self = .chat(accountID: userInfo["accountid"] as? String ?? "")
            case "steam":
                self = .steam
            case "fixes":
                self = .fixes(appID: userInfo["appid"] as? Int ?? 0)
            default:
                self = .friends
            }
        }
    }

    /// One notification in the words this app uses for it.
    ///
    /// Only types whose payload names itself (a message's sender and text, a
    /// download's app id) are presented; the rest are logged and dropped.
    ///
    /// To add a type, verify its fields against a live client first: fire
    /// `NotificationStore.GetNotificationTargets()[<type>].fnTest()` through
    /// `POST :8762/__eval` and read the decoded payload back out of
    /// `NotificationStore.m_rgNotificationTray`.
    struct Presentation {
        let title: String
        let body: String
        let route: Route
        /// Shown as a banner, then withdrawn from Notification Center.
        var isTransient = false
        /// True only for a message whose sender's Steam setting plays a sound.
        var isSounded = false

        init?(_ notification: SteamNotification) {
            let person = notification.title
            switch notification.kind {
            case 1:
                let game = notification.gameName.isEmpty ? InterfaceCopy.localized("A game") : notification.gameName
                title = game
                body = InterfaceCopy.localized("Download complete")
                route = .steam
            case 3:
                guard !person.isEmpty, !notification.gameName.isEmpty else { return nil }
                title = person
                body = String(localized: "is playing \(notification.gameName)")
                route = .chat(accountID: notification.accountID)
                isTransient = true
            case 4:
                guard !person.isEmpty else { return nil }
                title = person
                body = InterfaceCopy.localized("is now online")
                route = .chat(accountID: notification.accountID)
                isTransient = true
            case 8:
                guard !person.isEmpty else { return nil }
                title = person
                body = notification.body
                route = .chat(accountID: notification.accountID)
                isSounded = notification.playsSound ?? false
            case 9:
                guard !person.isEmpty else { return nil }
                title = person
                body = notification.body
                // Steam's group-chat route takes ids unverified against a live client.
                route = .friends
                isSounded = notification.playsSound ?? false
            default:
                return nil
            }
        }
    }

    /// The `UNUserNotificationCenterDelegate`, kept off the observable type.
    private final class Forwarder: NSObject, UNUserNotificationCenterDelegate {
        private weak var relay: SteamNotifications?

        init(relay: SteamNotifications) {
            self.relay = relay
        }

        /// Shown even while the app is active: it has no window that would say so.
        func userNotificationCenter(
            _: UNUserNotificationCenter,
            willPresent _: UNNotification,
        ) async -> UNNotificationPresentationOptions {
            [.banner, .list]
        }

        func userNotificationCenter(
            _: UNUserNotificationCenter,
            didReceive response: UNNotificationResponse,
        ) async {
            let userInfo = response.notification.request.content.userInfo
            let action = response.actionIdentifier
            await MainActor.run { relay?.handleResponse(action: action, userInfo: userInfo) }
        }
    }
}

extension UNAuthorizationStatus {
    /// The status in the log's words.
    var name: String {
        switch self {
        case .notDetermined: "not determined"
        case .denied: "denied"
        case .authorized: "authorized"
        case .provisional: "provisional"
        case .ephemeral: "ephemeral"
        @unknown default: "unknown"
        }
    }
}
