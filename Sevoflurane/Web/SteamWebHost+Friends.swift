import AppKit

extension SteamWebHost {
    /// Opens Steam's friends list as its own window, which needs nothing from
    /// the desktop window. With messages waiting it opens the oldest
    /// conversation instead, as Steam's tray badge does.
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
        // Activate now, while the click is still the reason: cooperative
        // activation declines a request it cannot attribute to an event.
        NSApp.activate()
        Task(name: "Open \(what)") {
            let result = await evaluateInContext(script)
            EventLog.shared.log(.window, "\(what): \(result ?? "no answer")")
        }
    }

    /// One notification from ``notificationScript``, identities resolved.
    func noteSteamNotification(json: String) {
        guard let data = json.data(using: .utf8),
              let notification = try? JSONDecoder().decode(SteamNotification.self, from: data)
        else {
            EventLog.shared.log(.app, "unreadable notification payload: \(json.prefix(200))")
            return
        }
        notifications?.post(notification)
        // The bottle's twin UI shows the same toast as a CEF window
        // (`notificationtoasts_N_desktop`); sweeping on the event hides it
        // before it is seen. ``PopupSweeper`` owns the schedule, so a second
        // notification lengthens the sweep instead of racing it.
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

    /// Opens the friends list, or through `ShowChatUnreadMessages` the oldest
    /// unread conversation (the plain list when nothing is unread).
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

    /// Subscribes the context page to `CurrentToastSubscribableValue`, the
    /// value Steam's toast component reads, so the user's Steam notification
    /// settings already apply. The payload arrives deserialized by Steam's
    /// own per-type descriptor (`GetNotificationTargets()[type].proto`).
    ///
    /// Identities are resolved here, where `friendStore` and `appStore` live;
    /// ``SteamNotifications`` writes the words.
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

    /// Installs the context page's standing subscriptions and refusals, each
    /// retried until settled: they need globals assigned partway through
    /// boot, with no ready signal. The chat and sound refusals also go to the
    /// bottled client's own friends UI.
    func installContextScripts() {
        install(
            Self.notificationScript,
            describedAs: "Steam notifications",
            settledAt: ["registered", "already registered"],
        )
        install(
            Self.overlayScript,
            describedAs: "Steam overlay activation",
            settledAt: ["registered", "already registered"],
        )
        install(
            Self.installWizardScript,
            describedAs: "Steam's install wizard",
            settledAt: ["registered", "already registered"],
        )
        install(
            Self.callFailureScript,
            describedAs: "Steam's refused calls",
            settledAt: ["registered", "already registered"],
        )
        install(
            SteamChatAutoOpen.refusalScript,
            describedAs: "unasked chat windows",
            settledAt: SteamChatAutoOpen.settled,
        )
        install(
            SteamMessageSound.refusalScript,
            describedAs: "Steam's own message sound",
            settledAt: SteamMessageSound.settled,
        )
        installInClient(
            SteamChatAutoOpen.refusalScript,
            describedAs: "unasked chat windows",
            settledAt: SteamChatAutoOpen.settled,
        )
        installInClient(
            SteamMessageSound.refusalScript,
            describedAs: "Steam's own message sound",
            settledAt: SteamMessageSound.settled,
        )
    }

    private func installInClient(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what) in the client") {
            let result = await ClientLifecycle.installInClientUI(script, settledAt: outcomes)
            EventLog.shared.log(.client, "\(what) in the client: \(result)")
        }
    }

    /// Evaluates `script` in the context page once a second for ten seconds
    /// until it answers one of `outcomes`. A result's words before a colon
    /// are its outcome.
    func install(
        _ script: String, describedAs what: String, settledAt outcomes: Set<String>,
    ) {
        Task(name: "Install \(what)") {
            for _ in 1 ... 10 {
                if let result = await evaluateInContext(script),
                   outcomes.contains(String(result.prefix { $0 != ":" })) {
                    EventLog.shared.log(.app, "\(what): \(result)")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            EventLog.shared.log(.app, "\(what): Steam's own globals never appeared")
        }
    }
}
