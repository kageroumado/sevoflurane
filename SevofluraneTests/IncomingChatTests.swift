import Foundation
import Testing
import UserNotifications
@testable import Sevoflurane

/// What happens when a message arrives, decided without a bottle.
///
/// Everything Steam does for an incoming message is refused in the page by
/// ``SteamChatAutoOpen``; what is left on this side is two decisions, and
/// both are values here. ``UnaskedChatPolicy`` says whether a chat window
/// Steam is showing was asked for, and ``SteamNotifications/Presentation``
/// says what a notification reads as and where its click goes. The clock is
/// an argument, so no test waits for anything.
///
/// The live half of the same scenarios is `Tools/chat-scenarios.sh`.
struct UnaskedChatPolicyTests {
    /// The moment every scenario starts from. Named so the offsets below read
    /// as "n seconds later".
    private let start = ContinuousClock.now

    @Test
    func `a message arrives with nobody touching the app`() {
        let policy = UnaskedChatPolicy(startingAt: start)
        // Steam shows the chat a moment after the message lands. No press, no
        // request: the window is Steam's idea, and it stays off screen.
        #expect(policy.showIsUnasked(at: start + .milliseconds(120)))
    }

    @Test
    func `a second message while the first is still held is also unasked`() {
        let policy = UnaskedChatPolicy(startingAt: start)
        #expect(policy.showIsUnasked(at: start + .seconds(30)))
        #expect(policy.showIsUnasked(at: start + .seconds(3600)))
    }

    @Test
    func `a chat the user opened from the friends list is shown`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteChatRequest(at: start)
        // `ShowFriendChatDialogWhenReady` waits for the friends UI, so the
        // show can arrive seconds after the click that caused it.
        #expect(!policy.showIsUnasked(at: start))
        #expect(!policy.showIsUnasked(at: start + .seconds(7)))
    }

    @Test
    func `a notification click opens the chat it came from`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        // The click routes through the same request path as the menu bar.
        policy.noteChatRequest(at: start + .seconds(600))
        #expect(!policy.showIsUnasked(at: start + .seconds(600.5)))
    }

    @Test
    func `a press in one of the app's windows counts for three seconds`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteUserInteraction(at: start)
        #expect(!policy.showIsUnasked(at: start + .seconds(1)))
        #expect(!policy.showIsUnasked(at: start + .seconds(2.9)))
        #expect(policy.showIsUnasked(at: start + .seconds(3.1)))
    }

    @Test
    func `a request counts for eight seconds`() {
        var policy = UnaskedChatPolicy(startingAt: start)
        policy.noteChatRequest(at: start)
        #expect(!policy.showIsUnasked(at: start + .seconds(7.9)))
        #expect(policy.showIsUnasked(at: start + .seconds(8.1)))
    }

    @Test
    func `either reason on its own is enough`() {
        var pressed = UnaskedChatPolicy(startingAt: start)
        pressed.noteUserInteraction(at: start + .seconds(5))
        #expect(!pressed.showIsUnasked(at: start + .seconds(6)))

        var requested = UnaskedChatPolicy(startingAt: start)
        requested.noteChatRequest(at: start + .seconds(5))
        #expect(!requested.showIsUnasked(at: start + .seconds(6)))
    }

    @Test
    func `the graces are the ones the host documents`() {
        #expect(UnaskedChatPolicy.interactionGrace == .seconds(3))
        #expect(UnaskedChatPolicy.requestGrace == .seconds(8))
    }
}

/// The window Steam names for a chat is classified as one, and a toast is
/// never showable — the two role facts the arrival path turns on.
@MainActor
struct ChatWindowRoleTests {
    @Test
    func `Steam's chat popup names classify as chats`() {
        #expect(SteamWindowRole(popupName: "chat_ChatWindow_0_uid0") == .chat)
        #expect(SteamWindowRole(popupName: "chat_ChatWindow_12_uid4231") == .chat)
        #expect(SteamWindowRole(popupName: "friendslist_uid0") == .friends)
        #expect(SteamWindowRole(popupName: "notificationtoasts_1_desktop") == .toast)
    }

    @Test
    func `a chat may be shown and a toast may not`() {
        #expect(SteamWindowRole.chat.isShowable)
        #expect(!SteamWindowRole.toast.isShowable)
    }
}

/// What a notification says and where its click goes.
@MainActor
struct SteamNotificationPresentationTests {
    /// The payload the context page posts, in the shape
    /// ``SteamWebHost`` builds it — Steam's own fields, identities already
    /// resolved.
    private static func payload(
        kind: Int,
        source: Int = 1,
        id: String = "9001",
        title: String = "",
        body: String = "",
        accountID: String = "37871103",
        gameName: String = "",
        appID: String = "",
        sound: Bool? = nil,
    ) throws -> SteamNotification {
        // `sound` is omitted rather than defaulted, so the payload an older
        // page builds is exercised too.
        let soundField = sound.map { ",\"sound\":\($0)" } ?? ""
        let json = """
        {"kind":\(kind),"source":\(source),"id":"\(id)","title":"\(title)",
         "body":"\(body)","icon":"https://avatars.steamstatic.com/x_medium.jpg",
         "steamid":"76561198035136831","accountid":"\(accountID)",
         "appid":"\(appID)","gameName":"\(gameName)"\(soundField)}
        """
        return try JSONDecoder().decode(
            SteamNotification.self, from: Data(json.utf8),
        )
    }

    @Test
    func `a message reads as its sender and opens their chat`() throws {
        let notification = try Self.payload(kind: 8, title: "Mika", body: "are you up?")
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(presentation.title == "Mika")
        #expect(presentation.body == "are you up?")
        #expect(presentation.route == .chat(accountID: "37871103"))
        // A conversation is one thread in Notification Center, however many
        // messages arrive while it is held.
        #expect(presentation.route.threadIdentifier == "chat-37871103")
        // A message is a record: it stays until the user deals with it.
        #expect(!presentation.isTransient)
    }

    @Test
    func `a message with no sender is dropped rather than posted unnamed`() throws {
        let notification = try Self.payload(kind: 8, body: "are you up?")
        #expect(SteamNotifications.Presentation(notification) == nil)
    }

    @Test
    func `a group message lands on the friends list`() throws {
        let notification = try Self.payload(kind: 9, title: "Game Night", body: "Mika: hey")
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(presentation.route == .friends)
    }

    @Test
    func `a friend starting a game is a banner and not a record`() throws {
        let notification = try Self.payload(kind: 3, title: "Mika", gameName: "Half-Life")
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(presentation.title == "Mika")
        #expect(presentation.body == "is playing Half-Life")
        #expect(presentation.isTransient)
    }

    @Test
    func `a friend coming online is a banner and not a record`() throws {
        let notification = try Self.payload(kind: 4, title: "Mika")
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(presentation.body == "is now online")
        #expect(presentation.isTransient)
    }

    @Test
    func `a type with no words here is dropped`() throws {
        #expect(SteamNotifications.Presentation(try Self.payload(kind: 44)) == nil)
    }

    @Test
    func `a message sounds when Steam's setting says it should`() throws {
        let notification = try Self.payload(kind: 8, title: "Mika", body: "hi", sound: true)
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(presentation.isSounded)
    }

    @Test
    func `a message stays silent when Steam's setting says silent`() throws {
        let notification = try Self.payload(kind: 8, title: "Mika", body: "hi", sound: false)
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(!presentation.isSounded)
    }

    @Test
    func `a payload with no answer about sound is silent`() throws {
        let notification = try Self.payload(kind: 8, title: "Mika", body: "hi")
        #expect(notification.playsSound == nil)
        let presentation = try #require(SteamNotifications.Presentation(notification))
        #expect(!presentation.isSounded)
    }

    @Test
    func `a group message carries the chat room's own sound setting`() throws {
        let loud = try Self.payload(kind: 9, title: "Game Night", body: "Mika: hey", sound: true)
        #expect(try #require(SteamNotifications.Presentation(loud)).isSounded)
        let quiet = try Self.payload(kind: 9, title: "Game Night", body: "Mika: hey", sound: false)
        #expect(try !#require(SteamNotifications.Presentation(quiet)).isSounded)
    }

    @Test
    func `the kinds whose sound Steam still plays stay silent here`() throws {
        // Presence keeps its own chime in the page, so the banner adds none —
        // saying `sound: true` for one of these changes nothing.
        for kind in [1, 3, 4] {
            let notification = try Self.payload(
                kind: kind, title: "Mika", gameName: "Half-Life", sound: true,
            )
            #expect(try !#require(SteamNotifications.Presentation(notification)).isSounded)
        }
    }

    @Test
    func `a click routes back to the chat it came from`() {
        let route = SteamNotifications.Route.chat(accountID: "37871103")
        #expect(SteamNotifications.Route(userInfo: route.userInfo) == route)
        #expect(SteamNotifications.Route(userInfo: [:]) == .friends)
    }
}

/// The pipeline in front of the presentation: what ``SteamNotifications``
/// refuses before macOS is ever asked.
@MainActor
struct SteamNotificationPostingTests {
    private static func payload(kind: Int, source: Int) throws -> SteamNotification {
        let json = """
        {"kind":\(kind),"source":\(source),"id":"9002","title":"Mika","body":"hi",
         "icon":"","steamid":"76561198035136831","accountid":"37871103",
         "appid":"","gameName":""}
        """
        return try JSONDecoder().decode(SteamNotification.self, from: Data(json.utf8))
    }

    @Test
    func `a message with nobody asked yet raises the popover's prompt`() throws {
        let relay = SteamNotifications.preview(authorization: .notDetermined)
        relay.post(try Self.payload(kind: 8, source: 1))
        #expect(relay.hasUnaskedNotifications)
    }

    @Test
    func `a server-sourced notification is left to Steam's own surfaces`() throws {
        let relay = SteamNotifications.preview(authorization: .notDetermined)
        relay.post(try Self.payload(kind: 8, source: 2))
        #expect(!relay.hasUnaskedNotifications)
    }

    @Test
    func `a type with no words here never reaches macOS`() throws {
        let relay = SteamNotifications.preview(authorization: .notDetermined)
        relay.post(try Self.payload(kind: 44, source: 1))
        #expect(!relay.hasUnaskedNotifications)
    }
}

/// The refusals themselves: two scripts, each installed in both copies of the
/// friends UI, whose answers the retry loops compare against.
struct SteamChatAutoOpenTests {
    @Test
    func `the sound refusal names the three sounds a message makes`() {
        let script = SteamMessageSound.refusalScript
        #expect(script.contains("PlayAudioURL"))
        for file in SteamMessageSound.refusedFiles {
            #expect(script.contains(file))
        }
        // The friend-join and friend-online chimes go through the same
        // method and are not ours to take over.
        #expect(!script.contains("ui_steam_smoother_friend_join"))
    }

    @Test
    func `both refusals settle on the same two answers`() {
        #expect(SteamMessageSound.settled == SteamChatAutoOpen.settled)
    }

    @Test
    func `the refusal names the one method that gates the auto-open`() {
        #expect(SteamChatAutoOpen.refusalScript.contains("BShowIncomingChatMessages"))
        #expect(SteamChatAutoOpen.refusalScript.contains("g_FriendsUIApp"))
    }

    @Test
    func `a second install is recognized rather than repeated`() {
        #expect(SteamChatAutoOpen.settled.contains("refused"))
        #expect(SteamChatAutoOpen.settled.contains("already refused"))
        // "unavailable" is Steam's globals not being up yet, which is what
        // the retry loops are for.
        #expect(!SteamChatAutoOpen.settled.contains("unavailable"))
    }
}
