import Foundation

/// The chime Steam plays for an arriving message, refused in both copies of
/// the friends UI so the Mac's notification is the only thing that sounds.
///
/// Steam plays the sound from the page, apart from the toast:
/// `CFriendChat.PlayFriendMessageSound` and the chat room's
/// `PlayChatRoomNotificationSound` / `PlayAtMentionSound` each call
/// `AudioPlaybackManager.PlayAudioURL` with one file under
/// `public/sounds/webui/`. All three play while the chat's visibility state
/// is below active, which is always the case once ``SteamChatAutoOpen``
/// refuses the auto-open popup.
///
/// On a Mac the one sound per message belongs to the notification, where the
/// volume, Do Not Disturb and the per-app switch are the system's, so
/// ``SteamNotifications`` carries it instead, under Steam's own setting.
///
/// The wrap is on `PlayAudioURL`, where the three calls meet, and drops only
/// those three files: the friend-join and friend-online sounds use the same
/// method and still play, since nothing here announces those events.
nonisolated enum SteamMessageSound {
    /// Matched by path, whatever CDN host serves them.
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

    /// The answers that tell a retrying caller to stop.
    static let settled: Set<String> = ["refused", "already refused"]
}
