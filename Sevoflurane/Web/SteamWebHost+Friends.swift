import AppKit

extension SteamWebHost {
    /// Opens Steam's friends list as its own window.
    ///
    /// The friends list and every chat are ordinary popups of the UI this app
    /// already hosts, so they need nothing from the desktop window — which is
    /// the point: a menu-bar Steam is a launcher and a friends list, and the
    /// library is the optional part. Measured against a live client with
    /// `SP Desktop` hidden throughout.
    ///
    /// With messages waiting, this opens the oldest of them instead, the way
    /// clicking Steam's own tray badge does; Steam falls back to the plain
    /// list when nothing is unread.
    func openFriends() {
        runInContext(Self.friendsScript(unread: unreadChats > 0), describedAs: "friends list")
    }

    /// Opens one friend's chat window, by the 32-bit account id Steam's own
    /// chat calls take. Notification clicks land here.
    func openChat(accountID: String) {
        guard !accountID.isEmpty, let id = Int(accountID) else {
            openFriends()
            return
        }
        runInContext(Self.chatScript(accountID: id), describedAs: "chat with \(accountID)")
    }

    var chatShowIsUnasked: Bool {
        chatPolicy.showIsUnasked(at: .now)
    }

    private func runInContext(_ script: String, describedAs what: String) {
        chatPolicy.noteChatRequest(at: .now)
        // The window comes forward with the app, the way any window opened
        // from a menu-bar item does. Cooperative activation declines a
        // request it cannot attribute to an event, so this happens now,
        // while the click is still the reason for it.
        NSApp.activate()
        Task(name: "Open \(what)") {
            let result = await evaluateInContext(script)
            EventLog.shared.log(.window, "\(what): \(result ?? "no answer")")
        }
    }

    /// One notification from the context page's subscription
    /// (``notificationScript``), already decoded and with its identities
    /// resolved.
    func noteSteamNotification(json: String) {
        guard let data = json.data(using: .utf8),
              let notification = try? JSONDecoder().decode(SteamNotification.self, from: data)
        else {
            EventLog.shared.log(.app, "unreadable notification payload: \(json.prefix(200))")
            return
        }
        notifications?.post(notification)
        // The bottle's hidden twin UI renders the same toast as a CEF window
        // of its own (`notificationtoasts_N_desktop`), bottom-right on the
        // real desktop. The supervisor's sweep would catch it eventually;
        // catching it on the event is what keeps it from ever being seen.
        // The schedule belongs to ``PopupSweeper``, so a second notification
        // arriving mid-sweep lengthens this one instead of racing it.
        Task(name: "Hide client toast twin") {
            await PopupSweeper.shared.sweepAfterNotification { hidden in
                let names = hidden.names.joined(separator: ", ")
                EventLog.enqueue(
                    .client,
                    hidden.scope == .twins
                        ? "hid the client's own copy of what this app draws: \(names)"
                        : "hid the client's own CEF windows: \(names)",
                )
            }
        }
    }

    /// Opens the friends list, or the oldest unread conversation.
    ///
    /// `ShowChatUnreadMessages` is Steam's own "show me what is waiting": it
    /// picks the oldest unread chat and activates it, and opens the plain
    /// list when there is nothing unread after all.
    private static func friendsScript(unread: Bool) -> String {
        """
        (function () {
          var app = window.g_FriendsUIApp;
          if (!app || typeof app.GetDefaultBrowserContext !== "function") return "unavailable";
          var context = app.GetDefaultBrowserContext();
          if (!context) return "no browser context";
          var desktop = app.m_DesktopApp;
          if (\(unread ? "true" : "false")
              && desktop && typeof desktop.ShowChatUnreadMessages === "function") {
            desktop.ShowChatUnreadMessages(context);
            return "showing unread";
          }
          if (typeof app.ShowPopupFriendsList !== "function") return "unavailable";
          app.ShowPopupFriendsList(context, false, true);
          return "showing friends list";
        })()
        """
    }

    private static func chatScript(accountID: Int) -> String {
        """
        (function () {
          var app = window.g_FriendsUIApp;
          if (!app || !app.UIStore
              || typeof app.UIStore.ShowFriendChatDialogWhenReady !== "function") {
            return "unavailable";
          }
          var context = app.GetDefaultBrowserContext();
          if (!context) return "no browser context";
          app.UIStore.ShowFriendChatDialogWhenReady(context, \(accountID), true, true);
          return "showing chat";
        })()
        """
    }

    /// Subscribes the context page to Steam's own toast value.
    ///
    /// `CurrentToastSubscribableValue` is what Steam's toast component reads,
    /// so subscribing to it sees exactly the notifications Steam would have
    /// drawn — and the user's Steam notification settings, which are applied
    /// upstream of it, are honored without this app knowing they exist. The
    /// payload is deserialized by Steam's own per-type descriptor
    /// (`GetNotificationTargets()[type].proto`), so the schema can never
    /// drift from the client's.
    ///
    /// Identities are resolved here because only the page can resolve them:
    /// an account id is a persona in `friendStore`, an app id is a name in
    /// `appStore`. The words are written in ``SteamNotifications``.
    static let notificationScript = """
    (function () {
      if (window.__sevoNotifications) return "already registered";
      var store = window.NotificationStore;
      if (!store || !store.CurrentToastSubscribableValue) return "unavailable";
      window.__sevoNotifications = true;
    
      /* SteamID64 = account id + this. */
      var BASE = BigInt("76561197960265728");
    
      function accountID(steamid) {
        try { return String(BigInt(steamid) - BASE); } catch (e) { return ""; }
      }
    
      function persona(steamid) {
        try {
          var id = Number(accountID(steamid));
          if (!id) return "";
          /* GetFriendState takes Steam's own CSteamID, of which it uses
             exactly one method. */
          var state = window.friendStore.GetFriendState(
            { GetAccountID: function () { return id; } });
          return (state && state.display_name) || "";
        } catch (e) { return ""; }
      }
    
      function appName(appid) {
        try {
          var app = window.appStore.GetAppOverviewByAppID(Number(appid));
          return (app && app.display_name) || "";
        } catch (e) { return ""; }
      }
    
      /* Steam's own answer to "does this make a sound", asked here because
         only the page can ask it: a friend's message honors the per-friend
         override on top of Friends & Chat's bSounds_PlayMessage, and a group
         message reads bSounds_PlayChatRoomNotification. Steam's own playback
         is refused (SteamMessageSound) and the Mac's notification carries the
         sound instead, so this is the setting reaching the surface that now
         makes the noise. */
      function playsSound(kind, id) {
        try {
          var app = window.g_FriendsUIApp;
          if (kind === 9) return !!app.BPlayChatRoomNotificationSound();
          if (kind !== 8) return false;
          var player = window.friendStore.GetPlayer(Number(id));
          if (player && typeof player.BPlayMessageSound === "function") {
            return !!player.BPlayMessageSound();
          }
          return !!app.SettingsStore.FriendsSettings.bSounds_PlayMessage;
        } catch (e) { return false; }
      }
    
      store.CurrentToastSubscribableValue.Subscribe(function (toast) {
        if (!toast) return;
        var data = toast.data;
        var fields = data && data.toObject ? data.toObject() : {};
        var out = {
          kind: toast.eType,
          source: toast.eSource,
          id: String(toast.notificationID),
          title: fields.title || "",
          body: fields.body || "",
          icon: fields.icon || "",
          steamid: String(fields.steamid || fields.steamid_sender || ""),
          appid: fields.appid ? String(fields.appid) : "",
          gameName: fields.game_name || "",
        };
        out.accountid = out.steamid ? accountID(out.steamid) : "";
        if (!out.title && out.steamid) out.title = persona(out.steamid);
        if (!out.gameName && out.appid) out.gameName = appName(out.appid);
        out.sound = playsSound(out.kind, out.accountid);
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage(
            { fn: "__steamNotification", args: [JSON.stringify(out)] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
