import AppKit
import Observation
import UserNotifications

/// One notification Steam produced, as the context page reports it.
///
/// Steam hands its UI a notification id, a type, and a protobuf body whose
/// shape is chosen by that type. The page deserializes it with Steam's own
/// per-type descriptor and resolves the identities only it can resolve — an
/// account id to a persona, an app id to a game's name — so what arrives here
/// is already a set of names. The words are written on this side.
struct SteamNotification: Decodable, Equatable, Sendable {
    /// Steam's `ENotificationType`. The client's table runs 1…64; the ones
    /// this app can present are in ``SteamNotifications/Presentation``.
    var kind: Int
    /// Steam's `ENotificationSource`: 1 is the client, 2 is the Steam
    /// servers. Only the client's are presented — a server notification's
    /// body is a JSON blob whose rendering is Steam's own web component.
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
    /// Steam's own sound setting for this notification, answered in the page
    /// where it lives: the per-friend override over Friends & Chat's "play a
    /// sound when I receive a message" for a message, the chat-room switch
    /// for a group's. Absent from a payload an older page built, which reads
    /// as the silence that was the behavior then.
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
/// Steam draws its own toasts into a borderless popup in the corner of the
/// screen — a Windows toast over a Mac desktop, and one of the leaks this app
/// exists to remove. ``SteamWindowRole/toast`` keeps that popup off screen
/// while letting its page run, and what the user sees instead is posted here:
/// a real notification, with the sender's avatar, that opens the chat it came
/// from.
///
/// Nothing polls. The page subscribes to the same value Steam's own toast
/// component reads (`NotificationStore.CurrentToastSubscribableValue`), so
/// exactly the notifications Steam would have shown arrive here — the user's
/// Steam notification settings are honored because they are applied upstream
/// of that value.
@MainActor
@Observable
final class SteamNotifications {
    /// What macOS says about our permission to post.
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    /// Whether Steam has produced a notification that was dropped because
    /// nobody has been asked for permission yet. This is what the popover's
    /// prompt hangs on: an app with no window on first run has nowhere
    /// honest to raise the system alert until the feature has something to
    /// show for itself.
    private(set) var hasUnaskedNotifications = false

    /// Where a notification's click goes. Weak, because the host owns the
    /// app and this is one of the things it owns.
    @ObservationIgnored weak var host: SteamWebHost?

    @ObservationIgnored private let center: UNUserNotificationCenter?
    @ObservationIgnored private var delegate: Forwarder?

    init() {
        // `UNUserNotificationCenter.current()` traps in a process with no
        // bundle identifier — the gallery and the unit tests both run as one.
        center = Bundle.main.bundleIdentifier == nil ? nil : .current()
    }

    #if DEBUG
        /// A relay in a fixed permission state, for the gallery. It has no
        /// notification center behind it, so nothing it is asked to do
        /// reaches the real one.
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

    /// Installs the delegate and reads the current permission. Called at
    /// launch: reading the state raises no prompt, and the delegate has to be
    /// set before the app finishes launching for a click on a notification
    /// that woke the app to be delivered.
    func start() {
        guard let center else { return }
        let forwarder = Forwarder(relay: self)
        delegate = forwarder
        center.delegate = forwarder
        center.setNotificationCategories([Self.fixesCategory, Self.sessionCategory])
        Task(name: "Read notification authorization") { await refreshAuthorization() }
    }

    func refreshAuthorization() async {
        guard let center else { return }
        authorization = await center.notificationSettings().authorizationStatus
    }

    /// Raises the system permission alert. Only ever called from a control
    /// the user clicked — see ``hasUnaskedNotifications``.
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

    /// Posts one of Steam's notifications as the Mac's, or explains in the
    /// log why it did not.
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
        // A message makes one sound, and on a Mac it is the notification's:
        // the volume, the Do Not Disturb schedule and the per-app switch are
        // all the system's there. Steam plays its own chime from the page for
        // exactly these, which ``SteamMessageSound`` refuses, and the setting
        // behind it — Friends & Chat's "play a sound when I receive a
        // message", and any per-friend override on top — is what decides here
        // instead. Everything else stays silent: nothing on this side has
        // taken over the sound for it.
        content.sound = presentation.isSounded ? .default : nil
        content.userInfo = presentation.route.userInfo
        // Steam sends a new notification per message; grouping them by who
        // they are from is what makes a conversation read as one thread in
        // Notification Center rather than as n separate arrivals.
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
            // Presence is a moment, not a record: the banner shows, and
            // nothing lingers in Notification Center saying who was online
            // at 3pm. UserNotifications has no transient flag, so the
            // delivered notification is withdrawn once the banner has had
            // its time on screen.
            try? await Task.sleep(for: .seconds(8))
            center.removeDeliveredNotifications(withIdentifiers: [notification.id])
        }
    }

    /// The sender's avatar, fetched to a file so `UserNotifications` can take
    /// it. The framework moves the file into its own store, so each post gets
    /// its own copy and there is nothing here to clean up.
    private static func attachment(for notification: SteamNotification) async
        -> UNNotificationAttachment? {
        guard let url = URL(string: notification.icon),
              url.scheme == "https",
              let (data, _) = try? await URLSession.shared.data(from: url) else { return nil }
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

    /// Says that a game's first launch took the fix list's `settings`, with
    /// an Undo; a click opens the game in Settings › Games, which offers the
    /// same undo. Without permission to post it is a line in the log.
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
        content.body = String(localized: "Set by the fix list: \(settings.joined(separator: ", "))")
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

    /// Says that the bottle's Steam was signed out because its account
    /// signed in on another client, naming Steam for Mac when that is the
    /// one. Without permission to post it is a line in the log, and the menu
    /// bar says the same.
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

    /// Opens what a clicked notification was about. The friends list and a
    /// chat are their own windows, so none of this shows Steam's desktop
    /// window — the point of the feature.
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
        /// One friend's chat window.
        case chat(accountID: String)
        /// The friends list — the right landing for anything about a
        /// conversation this app cannot address directly.
        case friends
        /// Steam's own window, for the notifications that are about a game.
        case steam
        /// Settings › Games on one game, for what the fix list set on it.
        case fixes(appID: Int)

        var userInfo: [AnyHashable: Any] {
            switch self {
            case let .chat(accountID): ["open": "chat", "accountid": accountID]
            case .friends: ["open": "friends"]
            case .steam: ["open": "steam"]
            case let .fixes(appID): ["open": "fixes", "appid": appID]
            }
        }

        /// Groups a conversation's notifications into one thread in
        /// Notification Center.
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
    /// Steam's table runs to 64 types, and most of them carry a payload that
    /// only Steam's own React component knows how to render. These are the
    /// ones whose payload names itself — a message carries its sender and its
    /// text, a download carries its app id — so they can be written out here
    /// without guessing. Everything else is logged and dropped: a banner that
    /// can only say "Steam" is worse than no banner.
    ///
    /// To add a type, verify its fields against a live client first: fire
    /// `NotificationStore.GetNotificationTargets()[<type>].fnTest()` through
    /// `POST :8762/__eval` and read the decoded payload back out of
    /// `NotificationStore.m_rgNotificationTray`.
    struct Presentation {
        let title: String
        let body: String
        let route: Route
        /// Shown as a banner, then withdrawn from Notification Center —
        /// presence has no value as a record.
        var isTransient = false
        /// Whether the banner makes a sound. True only where Steam's own
        /// chime has been taken over — an arriving message — and only when
        /// Steam's setting for that sender says so.
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
                // A group chat is not one friend's window, and Steam's own
                // group-chat route takes a pair of ids this app has not
                // verified against a live client. The friends list is where
                // every conversation is reachable from.
                route = .friends
                isSounded = notification.playsSound ?? false
            default:
                return nil
            }
        }
    }

    /// The `UNUserNotificationCenterDelegate`, kept off the observable type
    /// so the state the popover reads is not also an `NSObject` full of
    /// protocol conformances.
    private final class Forwarder: NSObject, UNUserNotificationCenterDelegate {
        private weak var relay: SteamNotifications?

        init(relay: SteamNotifications) {
            self.relay = relay
        }

        /// This app has no window to be frontmost in, so a notification that
        /// arrives while it is active is still the only thing that says a
        /// message came in.
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
