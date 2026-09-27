import Foundation

/// The chime Steam plays for an arriving message, refused in both copies of
/// the friends UI so the Mac's notification is the only thing that sounds.
///
/// Steam plays its own sound from the page, not from the toast:
/// `CFriendChat.PlayFriendMessageSound` and the chat room's
/// `PlayChatRoomNotificationSound` / `PlayAtMentionSound` each call
/// `AudioPlaybackManager.PlayAudioURL` with one file under
/// `public/sounds/webui/`. All three are gated on the chat's visibility state
/// being below active, which was never true here while Steam was auto-opening
/// a popup for every message — so the sound was silent by accident, and
/// refusing that auto-open (``SteamChatAutoOpen``) turned it on.
///
/// One sound per message is the right number, and on a Mac it belongs to the
/// notification, where the volume, the Do Not Disturb schedule and the
/// per-app switch are the system's. So the page is quieted here and
/// ``SteamNotifications`` carries the sound instead, under Steam's own
/// setting either way.
///
/// The wrap is on `PlayAudioURL` because that is where the three calls meet,
/// and it drops only those three files: the friend-join and friend-online
/// sounds go through the same method and are left alone, because nothing on
/// this side has taken over what they announce.
nonisolated enum SteamMessageSound {
    /// The sounds Steam plays when a message arrives. Named by path so the
    /// CDN host in front of them does not matter.
    static let refusedFiles = [
        "public/sounds/webui/ui_steam_message_old_smooth.m4a",
        "public/sounds/webui/steam_chatroom_notification.m4a",
        "public/sounds/webui/steam_at_mention.m4a",
    ]

    /// Answers `"refused"`, `"already refused"`, or `"unavailable"` while
    /// Steam's globals are still coming up.
    static let refusalScript = """
    (function () {
      if (window.__sevoRefusedMessageSounds) return "already refused";
      var app = window.g_FriendsUIApp;
      var audio = app && app.AudioPlaybackManager;
      if (!audio || typeof audio.PlayAudioURL !== "function") return "unavailable";
      var refused = [\(refusedFiles.map { "\"\($0)\"" }.joined(separator: ", "))];
      var play = audio.PlayAudioURL.bind(audio);
      /* An own property over the prototype's method, so the class Steam
         wrote is left as it is for anything that reads it. */
      audio.PlayAudioURL = function (url) {
        var name = String(url);
        for (var i = 0; i < refused.length; i++) {
          if (name.indexOf(refused[i]) >= 0) return undefined;
        }
        return play.apply(null, arguments);
      };
      window.__sevoRefusedMessageSounds = true;
      return "refused";
    })()
    """

    /// The answers that mean the refusal is in place, so a caller retrying
    /// across Steam's boot knows to stop.
    static let settled: Set<String> = ["refused", "already refused"]
}
