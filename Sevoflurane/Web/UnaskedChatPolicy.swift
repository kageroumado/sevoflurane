import Foundation

/// Whether a chat window Steam is showing is one the user asked for.
///
/// Steam shows a chat window for reasons that are indistinguishable at the
/// `ShowWindow` call it makes: the user picked a conversation out of the
/// friends list, a notification click asked for one, or a message arrived and
/// Steam opened the conversation by itself. The `bFocus` argument does not
/// separate them — Steam passes it for its own reasons — so the host keeps
/// the two things it can see instead: the last press or key in one of this
/// app's windows, and the last time something on the user's behalf asked for
/// a chat or the friends list.
///
/// A show with neither behind it is Steam's own. The clock is passed in, so
/// every case is a value comparison and no test needs a bottle, a window, or
/// a sleep.
///
/// This is the backstop, not the cure: ``SteamChatAutoOpen`` stops Steam
/// opening the window at all, and this catches a show that arrives anyway —
/// a client whose globals came up after the refusal was installed, or a
/// future release that finds a second way to the same popup.
nonisolated struct UnaskedChatPolicy: Equatable, Sendable {
    /// How long a press or key in one of this app's windows keeps counting as
    /// the reason for the next chat Steam shows. Short: a click is a direct
    /// cause, and Steam acts on it in the same breath.
    static let interactionGrace: Duration = .seconds(3)

    /// How long an explicit request keeps counting. Longer, because
    /// `ShowFriendChatDialogWhenReady` is exactly that — Steam builds the
    /// window, waits for the friends UI to be ready, and only then shows it.
    static let requestGrace: Duration = .seconds(8)

    private var lastUserInteraction: ContinuousClock.Instant
    private var lastChatRequest: ContinuousClock.Instant

    /// A policy that has seen nothing yet: both graces long expired, so the
    /// first show Steam makes on its own is recognized as one.
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

    /// Whether a chat window Steam is showing now was opened for an incoming
    /// message rather than for the user.
    func showIsUnasked(at now: ContinuousClock.Instant) -> Bool {
        now - lastUserInteraction > Self.interactionGrace
            && now - lastChatRequest > Self.requestGrace
    }
}
