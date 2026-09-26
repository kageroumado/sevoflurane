import Foundation

extension SteamWebHost {
    /// One `__gameAction` event from the context page's registrations
    /// (``gameActionScript``). The trail also lands in the log, so a slow
    /// launch explains itself after the fact.
    func noteGameAction(phase: String, appID: String, task: String, actionID: String = "") {
        switch phase {
        case "start":
            lastLoggedLaunchTask = nil
            EventLog.shared.log(.client, "launch \(appID): \(task.isEmpty ? "begun" : task)")
            let id = Int(appID) ?? 0
            setLaunch(GameLaunch(appID: id, detail: "Preparing…", actionID: Int(actionID)), clearAfter: 180)
            if id != 0 { onGameLaunchStart?(id) }
        case "task":
            guard !task.isEmpty, task != "None" else { return }
            // Steam reports the same task several times a second while it runs.
            if lastLoggedLaunchTask != "\(appID):\(task)" {
                lastLoggedLaunchTask = "\(appID):\(task)"
                EventLog.shared.log(.client, "launch \(appID): \(task)")
            }
            let id = Int(appID) ?? activeLaunch?.appID ?? 0
            let actionID = activeLaunch?.appID == id ? activeLaunch?.actionID : nil
            setLaunch(GameLaunch(appID: id, detail: Self.launchTaskText(task), actionID: actionID), clearAfter: 180)
        case "end":
            // The launch flow is done but the engine still has to put up its
            // first window; GameLaunchWatch ends the story when it does. The
            // status outlives the flow for as long as that watch runs,
            // because which app is launching is what every window and every
            // process the launch starts is attributed to.
            EventLog.shared.log(.client, "launch flow finished — waiting for the game window")
            if var launch = activeLaunch {
                launch.detail = "Waiting for the game window…"
                setLaunch(launch, clearAfter: 180)
                launchOptionAnswers[launch.appID] = nil
            }
            // The end of a launch is the moment the user looks at the window
            // again, whether a game came up or an error dialog did, so it is
            // worth one check that there is something to look at.
            repairBlankDesktop()
        case "error":
            let id = Int(appID) ?? activeLaunch?.appID ?? 0
            EventLog.shared.log(
                .client,
                "launch \(id): Steam reported an error\(task.isEmpty ? "" : " — \(task)")",
            )
            if id != 0 {
                launchOptionAnswers[id] = nil
                onGameActionError?(id, task)
            }
        case "life":
            guard let id = Int(appID), id != 0 else { return }
            let running = task == "1"
            EventLog.shared.log(.client, "app \(id) \(running ? "is running" : "stopped running")")
            onGameRunningChanged?(id, running)
        default:
            break
        }
    }

    /// Steam's launch-pipeline task names, in user words. `Show*` tasks are
    /// the launch dialogs (EULA, launch options, playtime controls) — those
    /// wait on the user, not the machine. Unknown names fall back to the raw
    /// identifier spaced out: honest beats silent.
    private static func launchTaskText(_ task: String) -> String {
        switch task {
        case "ProcessingInstallScript": "Running the install script…"
        case "VerifyingFiles": "Verifying files…"
        case "SynchronizingCloud": "Syncing cloud saves…"
        case "SynchronizingControllerConfig": "Syncing controller config…"
        case "ProcessingShaderCache": "Processing shaders…"
        case "DownloadingWorkshop": "Updating Workshop items…"
        case "KickingOtherSession": "Signing out another session…"
        case "CreatingProcess", "Completed": "Starting the game…"
        case "WaitingGameWindow": "Waiting for the game window…"
        default:
            task.hasPrefix("Show")
                ? "Waiting for you…"
                : task.reduce(into: "") { result, character in
                    if character.isUppercase, !result.isEmpty { result.append(" ") }
                    result.append(result.isEmpty ? character : Character(character.lowercased()))
                } + "…"
        }
    }

    // MARK: - Launch options

    /// Steam asked how to start `appID` (`ShowLaunchOption`, tapped out of the
    /// page by the shim). Answered without asking when an answer was given
    /// ahead of time, when Steam remembers one from a "Forever" in its own
    /// dialog, or when there is nothing to choose between; otherwise a native
    /// alert asks, after this message handler returns.
    func noteLaunchOptions(appID: Int, actionID: Int, json: String, remembered: String) {
        guard launchOptionAction != actionID else { return }
        launchOptionAction = actionID
        let options = LaunchOptions.parse(json) { SteamAppInfo.launchDescriptions(appID: appID) }
        EventLog.shared.log(
            .client,
            "launch \(appID): Steam asks how to start it — \(options.count) option"
                + "\(options.count == 1 ? "" : "s"): \(LaunchOptions.summary(options))",
        )
        if let chosen = launchOptionAnswers.removeValue(forKey: appID) {
            EventLog.shared.log(.client, "launch \(appID): option \(chosen) chosen ahead of time")
            answerLaunchOptions(appID: appID, actionID: actionID, with: chosen, of: options)
            return
        }
        if let index = LaunchOptions.rememberedIndex(remembered, among: options) {
            EventLog.shared.log(.client, "launch \(appID): Steam remembers option \(index) for it")
            answerLaunchOptions(appID: appID, actionID: actionID, with: index, of: options)
            return
        }
        guard options.count > 1 else {
            answerLaunchOptions(appID: appID, actionID: actionID, with: options.first?.index ?? 0, of: options)
            return
        }
        if var launch = activeLaunch, launch.appID == appID {
            launch.detail = "Choose how to start it…"
            setLaunch(launch, clearAfter: 180)
        }
        launchOptionPending = appID
        let name = gameName(appID)
        // After this handler returns: a modal alert must not run inside a page message.
        ModalAlerts.present { [weak self] in
            let chosen = LaunchOptionPrompt.choose(from: options, for: name)
            guard let self else { return }
            launchOptionPending = nil
            answerLaunchOptions(appID: appID, actionID: actionID, with: chosen, of: options)
        }
    }

    /// Sends the answer through the page, the way its own dialog would have.
    /// Nil abandons the launch.
    private func answerLaunchOptions(appID: Int, actionID: Int, with index: Int?, of options: [LaunchOption]) {
        let script: String
        if let index {
            let label = options.first { $0.index == index }?.description ?? "option \(index)"
            EventLog.shared.log(.client, "launch \(appID): starting with option \(index) \u{201C}\(label)\u{201D}")
            script = LaunchOptions.continueScript(actionID: actionID, index: index)
        } else {
            EventLog.shared.log(.client, "launch \(appID): canceled at the chooser")
            script = LaunchOptions.cancelScript(actionID: actionID)
        }
        Task(name: "Answer how to start \(appID)") { _ = await evaluateInContext(script) }
    }

    /// Subscribes the context page to the client's game-action events and to
    /// the running edge of every app; they come back through the popup message
    /// handler as `__gameAction`.
    ///
    /// One registration per callback, recorded in a page global, so the script
    /// can be re-evaluated at any time and only registers what the page is
    /// missing. A reload drops the global with the page and re-registers,
    /// which is what a fresh page needs.
    ///
    /// `GameSessions.RegisterForAppLifetimeNotifications` is the only place a
    /// game's exit exists on this side: games are `CreateProcess`ed by
    /// `Steam.exe` inside the bottle, so the app has no pid to wait on.
    static let gameActionScript = """
    (function () {
      if (!window.SteamClient || !SteamClient.Apps
          || !SteamClient.Apps.RegisterForGameActionStart) return "unavailable";
      var registered = window.__sevoGameActions || (window.__sevoGameActions = {});
      var post = function (args) {
        try {
          window.webkit.messageHandlers.sevoWindow
            .postMessage({ fn: "__gameAction", args: args });
        } catch (e) {}
      };
      var added = 0;
      var once = function (key, available, register) {
        if (registered[key] || !available) return;
        registered[key] = register() || true;
        added++;
      };
      once("start", SteamClient.Apps.RegisterForGameActionStart, function () {
        return SteamClient.Apps.RegisterForGameActionStart(function (id, appid, action) {
          post(["start", String(appid), String(action || ""), String(id)]);
        });
      });
      once("task", SteamClient.Apps.RegisterForGameActionTaskChange, function () {
        return SteamClient.Apps.RegisterForGameActionTaskChange(function (id, appid, task) {
          post(["task", String(appid), String(task || "")]);
        });
      });
      once("end", SteamClient.Apps.RegisterForGameActionEnd, function () {
        return SteamClient.Apps.RegisterForGameActionEnd(function () {
          post(["end", "", ""]);
        });
      });
      once("error", SteamClient.Apps.RegisterForGameActionShowError, function () {
        return SteamClient.Apps.RegisterForGameActionShowError(
          function (id, appid, action, error, param) {
            post(["error", String(appid || ""),
                  [action, error, param].filter(Boolean).join(" ")]);
          });
      });
      once("life", window.SteamClient.GameSessions
           && SteamClient.GameSessions.RegisterForAppLifetimeNotifications, function () {
        return SteamClient.GameSessions.RegisterForAppLifetimeNotifications(function (change) {
          if (!change) return;
          post(["life", String(change.unAppID || ""), change.bRunning ? "1" : "0"]);
        });
      });
      return added ? "registered" : "already registered";
    })()
    """
}
