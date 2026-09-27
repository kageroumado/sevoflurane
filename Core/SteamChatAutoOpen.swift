import Foundation

/// Steam's answer to "does an incoming message raise a chat window", refused
/// in both copies of the friends UI a running Sevoflurane has.
///
/// Steam's friends UI opens a chat popup the moment a message arrives:
/// `CFriendMessages.IncomingMessage` calls `UIStore.ShowAndOrActivateChat`
/// when `g_FriendsUIApp.BShowIncomingChatMessages()` says so, which it does
/// for every client-hosted UI. Three things follow from that popup, and only
/// the first is one this side can undo:
///
/// - **The window.** A chat nobody asked for is put on screen. Hosted here it
///   is an `NSWindow`, and ``SteamWindow/show(activating:)`` can refuse it.
/// - **The read.** `CFriendChatView.OnActivate` calls `m_chat.OnActivate()`,
///   which zeroes the unread count and sends `FriendMessages.AckMessage` to
///   the server. It is reached from tab activation, from the popup's focus
///   handler, and from the `is_scrolled_to_bottom` setter, and **none of the
///   three consults the popup's visibility** — so a message is read the
///   moment its view exists, whatever this side does with the window.
/// - **The notification.** `CFriendChat.OnReceivedNewMessage` raises its toast
///   only while the chat's visibility state is below active, and a popup that
///   is open, current, visible and focused is exactly active. Steam suppresses
///   its own notification because it believes the user is already reading.
///
/// `BShowIncomingChatMessages` gates the auto-open and nothing else — it has
/// one call site in the whole bundle. Refused, the chat keeps no view, its
/// visibility state stays at "no popup", the message stays unread until the
/// user opens the conversation, and the toast fires — which is the one this
/// app re-posts as a real notification.
///
/// Both copies get it. The app's context page runs the friends UI the user
/// sees; the bottled client runs its own, whose CEF chat window lands on the
/// Wine desktop in front of everything until the popup sweep catches it.
nonisolated enum SteamChatAutoOpen {
    /// Answers `"refused"`, `"already refused"`, or `"unavailable"` while
    /// Steam's globals are still coming up.
    static let refusalScript = """
    (function () {
      if (window.__sevoRefusedChatAutoOpen) return "already refused";
      var app = window.g_FriendsUIApp;
      if (!app || typeof app.BShowIncomingChatMessages !== "function") {
        return "unavailable";
      }
      /* An own property over the prototype's method: the class is Steam's,
         and this leaves it untouched for anything that reads it. */
      app.BShowIncomingChatMessages = function () { return false; };
      window.__sevoRefusedChatAutoOpen = true;
      return "refused";
    })()
    """

    /// The answers that mean the refusal is in place, so a caller retrying
    /// across Steam's boot knows to stop.
    static let settled: Set<String> = ["refused", "already refused"]
}
