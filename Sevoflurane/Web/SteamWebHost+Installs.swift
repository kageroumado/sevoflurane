import AppKit

extension SteamWebHost {
    /// How long the install wizard has to sit on one page before the Steam window
    /// comes forward for it. A wizard `sevo app install` drives moves on within two
    /// seconds a page, so only one that waits for a person outlasts this.
    static let installWizardPatience: Duration = .seconds(3)

    /// The install wizard moved (``installWizardScript``). Steam draws the wizard —
    /// folder choice, license agreement — as a modal inside its main window, so an
    /// install started with that window off screen (from `sevo`, Quick Launch or a
    /// `steam://` link) waits on a dialog nobody can see. A wizard that holds one
    /// page for ``installWizardPatience`` brings the Steam window forward.
    func noteInstallWizard(state: Int, appID: String) {
        installWizardState = state
        installWizardUpdates += 1
        guard state != 0 else { return }
        let update = installWizardUpdates
        Task(name: "Show the install wizard") { [weak self] in
            try? await Task.sleep(for: Self.installWizardPatience)
            guard let self, installWizardUpdates == update, installWizardState != 0 else { return }
            guard !isSteamOnScreen else { return }
            EventLog.shared.log(
                .window,
                "install wizard for app \(appID) waits on page \(state) with Steam off screen; showing Steam",
            )
            // A closed Steam window is rebuilt by reloading the page, which
            // cancels the wizard: it is opened again once the window is up.
            if desktop == nil, !appID.isEmpty { installWizardToReopen = appID }
            showSteam()
        }
    }

    /// Opens the wizard a page rebuild cancelled, now that the Steam window it
    /// draws into is on screen.
    func reopenInstallWizardIfNeeded() {
        guard let appID = installWizardToReopen, let id = Int(appID) else { return }
        installWizardToReopen = nil
        Task(name: "Reopen the install wizard") {
            // The second argument is the client the install is for, "0" being this one.
            _ = await evaluateInContext("SteamClient.Installs.OpenInstallWizard([\(id)], \"0\"); 'ok'")
            EventLog.shared.log(.window, "install wizard for app \(id) reopened in the Steam window")
        }
    }

    /// Whether an install the page asked for goes ahead: at once for a game
    /// nothing known stands against, after ``InstallWarning`` for one that
    /// anti-cheat or an Unsupported verdict does. The warning follows the
    /// Mac compatibility switch, as the strip and the library's badges do.
    /// An install that goes ahead of a game set to its macOS version takes
    /// Steam for Mac's copy first, whichever button started it.
    func confirmInstall(appID: Int) async -> Bool {
        guard await passesCompatibilityWarning(appID: appID) else { return false }
        await takeSteamForMacCopy(appID: appID)
        return true
    }

    /// Clones Steam for Mac's copy into the library when the game is set to
    /// its macOS version, before Steam's wizard looks at the disk
    /// (``SteamForMacCopy``). A game set to Windows takes nothing: a macOS
    /// copy under a Windows install is files Steam would leave behind.
    private func takeSteamForMacCopy(appID: Int) async {
        guard Engine.running.supportsSteamPlayMacOS else { return }
        // Either source alone misses a case: the page's details are loaded
        // only for a game whose page was opened, and `config.vdf` takes a
        // mapping made moments ago only when Steam next writes it.
        let tool = JSLiteral.string(SteamPlayMacOS.toolName)
        let inPage = await evaluateInContext(
            "(function () { try { var d = appDetailsStore.GetAppDetails(\(appID)); return String(!!d && d.strCompatToolName === \(tool)); } catch (e) { return 'false'; } })()",
        )
        guard inPage == "true" || SteamPlayMacOS.mappedApps().contains(appID) else { return }
        switch await Self.take(appID: appID) {
        case let .cloned(copy, _, elapsed):
            EventLog.shared.log(
                .client,
                "install \(appID): cloned Steam for Mac's \(copy.installDir) (build \(copy.buildID ?? "?"), \(copy.bytes) bytes) "
                    + "in \(elapsed.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow))); Steam checks it",
            )
        case .nothing:
            break
        case let .failed(reason):
            EventLog.shared.log(.client, "install \(appID): Steam for Mac's copy not taken, so Steam downloads: \(reason)")
        }
    }

    /// Off the main actor: a large game is a large tree of file records.
    @concurrent
    private nonisolated static func take(appID: Int) async -> SteamForMacCopy.Taken {
        SteamForMacCopy.takeForInstall(appID: appID)
    }

    private func passesCompatibilityWarning(appID: Int) async -> Bool {
        guard Preferences.compatibilityStrip else { return true }
        let name = await evaluateInContext(
            "(function () { try { var o = appStore.GetAppOverviewByAppID(\(appID)); return (o && o.display_name) || ''; } catch (e) { return ''; } })()",
        ).flatMap { $0.isEmpty ? nil : $0 } ?? gameName(appID)
        let record = try? await withDeadline(InstallWarning.patience) {
            await GameCompatService.shared.record(appID: appID, name: name, deckCategory: nil)
        }
        guard let record, let risk = GameCompatVerdict.installRisk(record) else { return true }
        let nativePlays = record.nativeBadge.map { $0.state == .verified || $0.state == .playable } ?? false
        let install = await withCheckedContinuation { continuation in
            ModalAlerts.present {
                continuation.resume(returning: InstallWarning.ask(risk, name: name, nativePlays: nativePlays))
            }
        }
        EventLog.shared.log(
            .client,
            "install \(appID): warned (\(record.mac.label), anti-cheat \(record.antiCheatBadge.label)); "
                + (install ? "installing anyway" : "canceled"),
        )
        return install
    }

    /// Subscribes the context page to Steam's install wizard. Each update carries
    /// the install manager's state (`eInstallState`, 0 when the wizard is closed)
    /// and the app it is installing, and comes back through the popup message
    /// handler as `__installWizard`. Re-registered on reload.
    static let installWizardScript = """
    (function () {
      if (window.__sevoInstallWizard) return "already registered";
      if (!window.SteamClient || !SteamClient.Installs
          || !SteamClient.Installs.RegisterForShowInstallWizard) return "unavailable";
      window.__sevoInstallWizard = true;
      SteamClient.Installs.RegisterForShowInstallWizard(function (info) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage({
            fn: "__installWizard",
            args: [info && info.eInstallState || 0, String(info && info.currentAppID || "")],
          });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
