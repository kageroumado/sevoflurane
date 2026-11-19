import Foundation

/// Refuses Steam's auto-open of a chat window for an incoming message, in
/// both copies of the friends UI a running Sevoflurane has.
///
/// `CFriendMessages.IncomingMessage` calls `UIStore.ShowAndOrActivateChat`
/// when `g_FriendsUIApp.BShowIncomingChatMessages()` says so, which it does
/// for every client-hosted UI. The popup has three effects:
///
/// - **The window.** Hosted here it is an `NSWindow`, which
///   ``SteamWindow/show(activating:)`` can refuse.
/// - **The read.** `CFriendChatView.OnActivate` calls `m_chat.OnActivate()`,
///   which zeroes the unread count and sends `FriendMessages.AckMessage`. It
///   runs from tab activation, the popup's focus handler and the
///   `is_scrolled_to_bottom` setter, none of which checks the popup's
///   visibility, so hiding the window still marks the message read.
/// - **The notification.** `CFriendChat.OnReceivedNewMessage` raises its toast
///   only while the chat's visibility state is below active, and an open,
///   focused popup is active, so Steam suppresses its own notification.
///
/// `BShowIncomingChatMessages` gates only the auto-open (one call site in the
/// bundle). Refused, the chat keeps no view, the message stays unread until
/// the user opens the conversation, and the toast fires; the app re-posts it
/// as a real notification.
///
/// The app's context page runs the friends UI the user sees; the bottled
/// client runs its own, whose CEF chat window would land on the Wine desktop
/// in front of everything until the popup sweep catches it.
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

    /// The answers that tell a retrying caller to stop.
    static let settled: Set<String> = ["refused", "already refused"]
}
