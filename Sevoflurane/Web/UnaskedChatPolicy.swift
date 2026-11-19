import Foundation

/// Whether a chat window Steam is showing is one the user asked for.
///
/// Steam's `ShowWindow` (and its `bFocus`) looks the same whether the user
/// picked a conversation, clicked a notification, or a message arrived. So
/// the host tracks the last press or key in this app and the last chat
/// request; a show with neither recently behind it is Steam's own. The
/// clock is passed in, so tests need no window or sleep.
///
/// The backstop behind ``SteamChatAutoOpen``, for a show that arrives
/// anyway.
nonisolated struct UnaskedChatPolicy: Equatable, Sendable {
    /// How long a press or key counts as the reason for a chat show; Steam
    /// acts on a click at once.
    static let interactionGrace: Duration = .seconds(3)

    /// How long a chat request counts: `ShowFriendChatDialogWhenReady` waits
    /// for the friends UI before showing.
    static let requestGrace: Duration = .seconds(8)

    private var lastUserInteraction: ContinuousClock.Instant
    private var lastChatRequest: ContinuousClock.Instant

    /// A policy with both graces long expired.
    init(startingAt now: ContinuousClock.Instant) {
        let never = now - .seconds(3600)
        lastUserInteraction = never
        lastChatRequest = never
    }

    /// A press or a key in one of this app's windows.
    mutating func noteUserInteraction(at now: ContinuousClock.Instant) {
        lastUserInteraction = now
    }

    /// The menu bar, a notification click, or a `steam://` link asking for a
    /// chat or the friends list.
    mutating func noteChatRequest(at now: ContinuousClock.Instant) {
        lastChatRequest = now
    }

    /// Whether a chat show now was opened for an incoming message.
    func showIsUnasked(at now: ContinuousClock.Instant) -> Bool {
        now - lastUserInteraction > Self.interactionGrace
            && now - lastChatRequest > Self.requestGrace
    }
}
