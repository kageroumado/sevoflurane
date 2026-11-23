import Foundation

/// The library, app and download verbs, each a one-shot eval in
/// `SharedJSContext` against the bound `SteamClient` methods and the
/// `appStore` MobX store.
nonisolated enum SteamOps {
    /// `appStore.allApps` projected to stable fields.
    static func libraryList(installedOnly: Bool) async throws -> String {
        let filter = installedOnly ? ".filter(here)" : ""
        let js = """
        (() => { \(installedHere) return JSON.stringify(appStore.allApps\(filter).map(a => ({
          appid: a.appid, name: a.display_name, installed: here(a),
          size_on_disk: a.size_on_disk || null,
          minutes_playtime: a.minutes_playtime || 0 }))); })()
        """
        return try await SteamJS.eval(js) ?? "[]"
    }

    /// `here(a)`: installed in this bottle. Steam's own `installed` is also
    /// true for another of the account's clients (a native Mac Steam, another
    /// PC); `elsewhere(a)` names those.
    static let installedHere = """
    const here = a => !!(a.local_per_client_data && a.local_per_client_data.installed);
    const elsewhere = a => (a.per_client_data || [])
      .filter(c => c.installed && c.clientid !== "0").map(c => c.client_name);
    """

    /// One app's overview, `null` when the appid is not in the library.
    /// `steam_deck_compat_category`: 0 unknown, 1 unsupported, 2 playable,
    /// 3 verified.
    static func appInfo(_ appid: Int) async throws -> String {
        let js = """
        (() => {
          \(installedHere)
          const a = appStore.allApps.find(x => x.appid === \(appid));
          if (!a) return "null";
          return JSON.stringify({
            appid: a.appid, name: a.display_name, installed: here(a),
            installed_elsewhere: here(a) ? [] : elsewhere(a),
            size_on_disk: a.size_on_disk || null,
            minutes_playtime: a.minutes_playtime || 0,
            deck_compat_category: a.steam_deck_compat_category ?? null,
            update_state: a.per_client_data?.clientdata?.status ?? null,
            display_status: a.display_status ?? null });
        })()
        """
        return try await SteamJS.eval(js) ?? "null"
    }

    /// What Steam's library shows under an app's name, by the client's numbering.
    nonisolated enum DisplayStatus {
        /// A Steam Cloud sync. A game force-ended mid-sync keeps it, and the client
        /// drops every later launch of it until the client restarts.
        static let synchronizing = 8
    }

    /// An app's display status, `nil` when the appid is not in the library.
    static func displayStatus(_ appid: Int) async throws -> Int? {
        let js = "(() => String(appStore.GetAppOverviewByAppID(\(appid))?.display_status ?? ''))()"
        return try await SteamJS.eval(js).flatMap { Int($0.trimmingCharacters(in: CharacterSet(charactersIn: "\""))) }
    }

    static func launch(_ appid: Int) async throws {
        _ = try await SteamJS.eval(
            "\(SteamSurface.Call.runGame.invocation("'\(appid)'", "''", "-1", "100")); 'ok'",
        )
    }

    /// Where a launch went: the app's page, whose chooser can answer Steam's
    /// launch-option question, or the client, where only a given option can.
    enum LaunchRoute { case app, client }

    /// Starts an app the way the menu does. With supervision running, the
    /// daemon's `/game/launch` takes it (staging a game pinned to another
    /// renderer and restarting the client first) and hands it to the app when
    /// one is attached. Otherwise, or when no app took it, the launch is made
    /// in the client's own context.
    static func requestLaunch(_ appid: Int, option: Int?) async throws -> LaunchRoute {
        if await AppControl.status() != nil {
            var path = "/game/launch?appid=\(appid)"
            if let option { path += "&option=\(option)" }
            if let data = await AppControl.post(path, timeout: 300) {
                let reply = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
                // A daemon that does not report delivery hands every launch
                // to its app.
                let delivered = if let answer = reply?["delivered"] as? Bool {
                    answer
                } else {
                    await AppControl.appIsAlive()
                }
                if delivered { return .app }
            }
        }
        if let option {
            try await launch(appid, answering: option)
        } else {
            try await launch(appid)
        }
        return .client
    }

    /// Starts an app answering Steam's launch-option question with `option`,
    /// for when no app can ask the user.
    static func launch(_ appid: Int, answering option: Int) async throws {
        _ = try await SteamJS.eval(LaunchOptions.runAnsweringScript(appID: appid, option: option))
    }

    /// The task Steam's pending game action for `appid` waits on the user
    /// for (`ShowLaunchOption`, a EULA, a CD key), or `nil` when none waits.
    static func pendingUserRequest(_ appid: Int) async -> String? {
        let js = """
        new Promise(function (answer) {
          SteamClient.Apps.GetGameActionForApp('\(appid)', function (id) {
            if (id == null || id < 0) return answer('');
            SteamClient.Apps.GetGameActionDetails(id, function (d) {
              answer(d && d.bWaitingForUI ? String(d.strTaskName || '') : '');
            });
          });
        })
        """
        let task = await (try? SteamJS.eval(js))?.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        return task?.isEmpty == false ? task : nil
    }

    /// The ways Steam lists to start an app, as the client's JSON.
    static func launchOptions(_ appid: Int) async throws -> String {
        try await SteamJS.eval(LaunchOptions.listScript(appID: appid)) ?? "[]"
    }

    /// Asks the client to end `appid`, noting the stop request unless the
    /// caller already did: a second note would outlive the run and label the
    /// next one's ending.
    static func terminate(_ appid: Int, notingStop: Bool = true) async throws {
        if notingStop { RunLog.noteStopRequest(forApp: appid, by: .tool) }
        _ = try await SteamJS.eval(
            "\(SteamSurface.Call.terminateApp.invocation("'\(appid)'", "false")); 'ok'",
        )
    }

    /// The app ids Steam's own UI store believes are running.
    ///
    /// `RunGame` consults this store: an app that kept its entry after its
    /// process died makes every later launch of any app a silent no-op, even
    /// across a client restart. A launch reads it first, and a terminate
    /// waits on it.
    static func runningApps() async throws -> [Int] {
        let js = "(() => JSON.stringify((SteamUIStore.RunningApps || [])"
            + ".map(a => Number(a.appid)).filter(n => n > 0)))()"
        guard let text = try await SteamJS.eval(js) else { return [] }
        return Self.appIDs(inJSON: text)
    }

    /// The ids in a `RunningApps` reply, given as JSON text; each id may be
    /// a number or a string, depending on the client version.
    static func appIDs(inJSON text: String) -> [Int] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            return []
        }
        return list.compactMap { value in
            (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
        }
    }

    static func verify(_ appid: Int) async throws {
        _ = try await SteamJS.eval("\(SteamSurface.Call.verifyApp.invocation("\(appid)")); 'ok'")
    }

    /// The promptless install flow: open the wizard for the appid, wait until it
    /// holds the app, then continue with the defaults through each of its pages
    /// (folder, shortcuts, license) until the wizard closes. Returns `ok`,
    /// `no-wizard` when it never took the app (no license on the account),
    /// `license` when Steam shows the game's license agreement and
    /// `acceptLicense` is off, `ok license-accepted` when it was on,
    /// `stuck in state <n>`, or `error <code> <detail>`.
    ///
    /// The agreement page is install state 8, and its Accept is the primary
    /// button of a dialog in one of the client's popup documents; matching on
    /// the state keeps this independent of the client's language.
    @discardableResult
    static func install(_ appid: Int, acceptLicense: Bool = false) async throws -> String {
        let js = """
        (async () => {
          const pause = ms => new Promise(r => setTimeout(r, ms));
          // The second argument is the client the install is for, "0" being this one.
          SteamClient.Installs.OpenInstallWizard([\(appid)], "0");
          let info;
          for (let i = 0; i < 20; i++) {
            await pause(500);
            info = await SteamClient.Installs.GetInstallManagerInfo();
            if (info.rgApps?.some(a => a.nAppID === \(appid))) break;
          }
          if (!info.rgApps?.some(a => a.nAppID === \(appid))) return 'no-wizard';
          SteamClient.Installs.SetCreateShortcuts(false, false);
          let accepted = false;
          for (let i = 0; i < 6 && info.eInstallState !== 0; i++) {
            if (info.eInstallState === 8) {
              if (!\(acceptLicense)) return 'license';
              const button = g_PopupManager.GetPopups()
                .map(p => p.window?.document).filter(Boolean)
                .flatMap(d => [...d.querySelectorAll('button')])
                .find(b => /Primary/.test(b.className) && b.offsetParent);
              if (!button) return 'license';
              button.click();
              accepted = true;
            } else {
              SteamClient.Installs.ContinueInstall();
            }
            await pause(2000);
            info = await SteamClient.Installs.GetInstallManagerInfo();
            if (info.eAppError) return `error ${info.eAppError} ${info.errorDetail}`;
          }
          if (info.eInstallState !== 0) return `stuck in state ${info.eInstallState}`;
          return accepted ? 'ok license-accepted' : 'ok';
        })()
        """
        return try await SteamJS.eval(js) ?? "no-wizard"
    }

    /// Uninstall wants the caller to have echoed the app's name; the CLI and
    /// MCP layers enforce that before calling here.
    static func uninstall(_ appid: Int) async throws {
        _ = try await SteamJS.eval(
            // The second argument is the client the uninstall is for, "0" being this one.
            "\(SteamSurface.Call.openUninstallWizard.invocation("[\(appid)]", SteamSurface.thisClient, "true")); 'ok'",
        )
    }

    /// The display name, for uninstall's echo guard.
    static func appName(_ appid: Int) async throws -> String? {
        let js = "(() => appStore.allApps.find(x => x.appid === \(appid))?.display_name ?? null)()"
        return try await SteamJS.eval(js)
    }

    /// One `RegisterForDownloadOverview` snapshot: subscribe, take the first
    /// push, unregister. The overview's `progress[]` stage 3 (written to
    /// disk) is the overall percentage.
    static func downloadsStatus() async throws -> String {
        let js = """
        (() => new Promise(resolve => {
          let done = false;
          const finish = (value, handle) => {
            if (done) return; done = true;
            try { handle?.unregister?.(); } catch (e) {}
            resolve(value);
          };
          const h = SteamClient.Downloads.RegisterForDownloadOverview(o => {
            finish(JSON.stringify(o), h);
          });
          setTimeout(() => finish("null", h), 3000);
        }))()
        """
        return try await SteamJS.eval(js) ?? "null"
    }

    /// Global pause/resume is `EnableAllDownloads` — the client has no
    /// PauseDownloads; per-app pausing is `PauseAppUpdate(appid)`.
    static func setDownloadsEnabled(_ enabled: Bool) async throws {
        _ = try await SteamJS.eval(
            // The second argument is the client the downloads are on, "0" being this one.
            "\(SteamSurface.Call.enableAllDownloads.invocation("\(enabled)", SteamSurface.thisClient)); 'ok'",
        )
    }

    /// `set_download_throttle` in KB/s; 0 turns throttling off.
    static func throttle(_ kbps: Int) async throws {
        _ = try await SteamJS.eval(
            "\(SteamSurface.Call.execCommand.invocation("'set_download_throttle \(kbps)'")); 'ok'",
        )
    }
}

/// Whether a game has actually stopped. Steam's record and the bottle's
/// processes disagree both ways (a dead game can keep its `RunningApps`
/// entry; Subnautica 2 held a full core for 21 minutes after Steam forgot
/// it), so a game is gone only when neither sees it.
nonisolated enum GameStop {
    /// `terminated`: it went when Steam asked. `killed`: its processes had
    /// to be signaled. `stillRunning`: something survived both.
    enum Verdict: String, Sendable {
        case terminated
        case killed
        case stillRunning = "still running"
    }

    struct Sighting: Sendable, Equatable {
        let steamListsIt: Bool
        let processes: [pid_t]

        var isGone: Bool {
            !steamListsIt && processes.isEmpty
        }

        /// The half-sentence a report appends to a verdict.
        var description: String {
            switch (steamListsIt, processes.isEmpty) {
            case (true, true): "Steam still lists it"
            case (true, false): "Steam still lists it, and \(processes.count) of its "
                + "process\(processes.count == 1 ? "" : "es") answer: \(processes)"
            case (false, false): "\(processes.count) of its "
                + "process\(processes.count == 1 ? "" : "es") answer: \(processes)"
            case (false, true): "nothing answers"
            }
        }
    }

    static func sighting(ofApp appid: Int) async -> Sighting {
        let listed = await (try? SteamOps.runningApps())?.contains(appid) ?? false
        return await Sighting(steamListsIt: listed, processes: GameEnding.processes(ofApp: appid))
    }

    /// Polls once a second until the game is gone or `seconds` run out.
    static func waitUntilGone(appid: Int, seconds: Int) async -> Sighting {
        var last = await sighting(ofApp: appid)
        for _ in 0 ..< max(seconds, 0) {
            if last.isGone { return last }
            try? await Task.sleep(for: .seconds(1))
            last = await sighting(ofApp: appid)
        }
        return last
    }
}
