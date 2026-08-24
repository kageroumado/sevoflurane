import Foundation

/// The library/app/download verbs, all one-shot evals against
/// `SharedJSContext` — the ~15 bound SteamClient methods from SPEC plus the
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
    /// 3 verified — on every overview already (SPEC, Deck-mode section).
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

    static func verify(_ appid: Int) async throws {
        _ = try await SteamJS.eval("SteamClient.Apps.VerifyApp(\(appid)); 'ok'")
    }

    /// The promptless install flow: open the wizard for the appid, give the
    /// dialog stores a moment to populate, then continue with the defaults —
    /// the same two-step the bridge's `install` command uses.
    static func install(_ appid: Int) async throws {
        _ = try await SteamJS.eval("SteamClient.Installs.OpenInstallWizard([\(appid)]); 'ok'")
        try? await Task.sleep(for: .milliseconds(500))
        _ = try await SteamJS.eval("SteamClient.Installs.ContinueInstall(); 'ok'")
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
    /// disk) is the honest overall percentage (SPEC, determinations table).
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
