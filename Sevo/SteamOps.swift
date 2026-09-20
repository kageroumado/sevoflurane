import Foundation

/// The library/app/download verbs, all one-shot evals against
/// `SharedJSContext` — the ~15 bound SteamClient methods plus the
/// `appStore` MobX snapshot the bridge already relies on.
nonisolated enum SteamOps {
    /// `appStore.allApps` projected to the stable fields the spec promises.
    static func libraryList(installedOnly: Bool) async throws -> String {
        let filter = installedOnly ? ".filter(a => a.installed)" : ""
        let js = """
        (() => JSON.stringify(appStore.allApps\(filter).map(a => ({
          appid: a.appid, name: a.display_name, installed: !!a.installed,
          size_on_disk: a.size_on_disk || null,
          minutes_playtime: a.minutes_playtime || 0 }))))()
        """
        return try await SteamJS.eval(js) ?? "[]"
    }

    /// One app's overview, `null` when the appid is not in the library.
    /// `steam_deck_compat_category`: 0 unknown, 1 unsupported, 2 playable,
    /// 3 verified — on every overview already.
    static func appInfo(_ appid: Int) async throws -> String {
        let js = """
        (() => {
          const a = appStore.allApps.find(x => x.appid === \(appid));
          if (!a) return "null";
          return JSON.stringify({
            appid: a.appid, name: a.display_name, installed: !!a.installed,
            size_on_disk: a.size_on_disk || null,
            minutes_playtime: a.minutes_playtime || 0,
            deck_compat_category: a.steam_deck_compat_category ?? null,
            update_state: a.per_client_data?.clientdata?.status ?? null });
        })()
        """
        return try await SteamJS.eval(js) ?? "null"
    }

    static func launch(_ appid: Int) async throws {
        _ = try await SteamJS.eval(
            "SteamClient.Apps.RunGame('\(appid)', '', -1, 100); 'ok'",
        )
    }

    static func terminate(_ appid: Int) async throws {
        _ = try await SteamJS.eval(
            "SteamClient.Apps.TerminateApp('\(appid)', false); 'ok'",
        )
    }

    /// The app ids Steam's own UI store believes are running.
    ///
    /// The store is what `RunGame` consults: an app that kept its entry after
    /// its process died makes every later launch — of any app — a silent
    /// no-op, across a client restart too. So a launch reads this before it
    /// asks, and a terminate waits on it afterwards.
    static func runningApps() async throws -> [Int] {
        let js = "(() => JSON.stringify((SteamUIStore.RunningApps || [])"
            + ".map(a => Number(a.appid)).filter(n => n > 0)))()"
        guard let text = try await SteamJS.eval(js) else { return [] }
        return Self.appIDs(inJSON: text)
    }

    /// The ids in a `RunningApps` reply. Steam has spelled the id as a number
    /// and as a string over the client's life, and the reply arrives as the
    /// JSON text of whatever it holds.
    static func appIDs(inJSON text: String) -> [Int] {
        guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [Any] else {
            return []
        }
        return list.compactMap { value in
            (value as? NSNumber)?.intValue ?? (value as? String).flatMap(Int.init)
        }
    }

    static func verify(_ appid: Int) async throws {
        _ = try await SteamJS.eval("SteamClient.Apps.VerifyApp(\(appid)); 'ok'")
    }

    /// The promptless install flow: open the wizard for the appid, wait until it
    /// holds the app, then continue with the defaults through each of its pages
    /// (folder, shortcuts, license) until the wizard closes. Returns what the
    /// wizard said when it stopped: `ok`, `no-wizard` when it never took the app
    /// (an app the account holds no license for), `license` when Steam is showing
    /// the game's license agreement and `acceptLicense` is off, `ok license-accepted`
    /// when it was on and the agreement was accepted on the way, or
    /// `error <code> <detail>`.
    ///
    /// The agreement page is install state 8. Its dialog lives in one of the
    /// client's popup documents and its Accept is that dialog's primary button;
    /// the state is what identifies it, so the client's language does not matter.
    @discardableResult
    static func install(_ appid: Int, acceptLicense: Bool = false) async throws -> String {
        let js = """
        (async () => {
          const pause = ms => new Promise(r => setTimeout(r, ms));
          SteamClient.Installs.OpenInstallWizard([\(appid)]);
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
            "SteamClient.Installs.OpenUninstallWizard([\(appid)], true); 'ok'",
        )
    }

    /// The install-name check for uninstall's echo guard.
    static func appName(_ appid: Int) async throws -> String? {
        let js = "(() => appStore.allApps.find(x => x.appid === \(appid))?.display_name ?? null)()"
        return try await SteamJS.eval(js)
    }

    /// One `RegisterForDownloadOverview` snapshot: subscribe, take the first
    /// push, unregister. The overview's `progress[]` stage 3 (written to
    /// disk) is the honest overall percentage.
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
            "SteamClient.Downloads.EnableAllDownloads(\(enabled)); 'ok'",
        )
    }

    /// `set_download_throttle` in KB/s; 0 turns throttling off.
    static func throttle(_ kbps: Int) async throws {
        _ = try await SteamJS.eval(
            "SteamClient.Console.ExecCommand('set_download_throttle \(kbps)'); 'ok'",
        )
    }
}

/// Whether a game has actually stopped, and what it took.
///
/// Steam's record and the bottle's processes disagree in both directions: a
/// game that died can keep its `RunningApps` entry, and a game Steam has
/// forgotten can still hold a core (Subnautica 2 sat 21 minutes at a full
/// core with no window). Both are asked, and only a game neither can see is
/// gone.
nonisolated enum GameStop {
    /// What a terminate ended up doing. `terminated`: the game went when
    /// Steam asked. `killed`: it did not, and its processes were signaled.
    /// `stillRunning`: something answered to the end.
    enum Verdict: String, Sendable {
        case terminated
        case killed
        case stillRunning = "still running"
    }

    /// What is still there: Steam's entry, the bottle's processes, or both.
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

    /// The game's own processes in this bottle, named from its executables:
    /// every plausible exe in a Steam game's install directory, the one file
    /// an adopted program is. An app whose files cannot be placed has no name
    /// to match, and then only Steam's record speaks.
    static func processes(ofApp appid: Int) async -> [pid_t] {
        let names = executableNames(ofApp: appid)
        guard !names.isEmpty else { return [] }
        return await ClientLifecycle.bottleProcessIDs(matchingAnyOf: names)
    }

    static func executableNames(ofApp appid: Int) -> [String] {
        if AdoptedPrograms.isAdopted(appid) {
            return AdoptedPrograms.program(appid)
                .map { [$0.url.lastPathComponent.lowercased()] } ?? []
        }
        guard let directory = SharedGames.installDirectory(appID: appid) else { return [] }
        return GameExecutables.executables(in: directory)
    }

    static func sighting(ofApp appid: Int) async -> Sighting {
        let listed = await (try? SteamOps.runningApps())?.contains(appid) ?? false
        return await Sighting(steamListsIt: listed, processes: processes(ofApp: appid))
    }

    /// Polls until the game is gone or the seconds run out.
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
