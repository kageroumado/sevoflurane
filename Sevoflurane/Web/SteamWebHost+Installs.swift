import AppKit

extension SteamWebHost {
    /// How long the install wizard may sit on one page before Steam comes
    /// forward; `sevo app install` moves on within two seconds a page.
    static let installWizardPatience: Duration = .seconds(3)

    /// The install wizard moved (``installWizardScript``). It is a modal
    /// inside Steam's main window, so one that holds a page for
    /// ``installWizardPatience`` with that window off screen brings it forward.
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
            // Rebuilding a closed window reloads the page and cancels the
            // wizard, so it is reopened after.
            if desktop == nil, !appID.isEmpty { installWizardToReopen = appID }
            showSteam()
        }
    }

    /// Reopens the wizard a page rebuild cancelled.
    func reopenInstallWizardIfNeeded() {
        guard let appID = installWizardToReopen, let id = Int(appID) else { return }
        installWizardToReopen = nil
        Task(name: "Reopen the install wizard") {
            // The second argument is the client the install is for, "0" being this one.
            _ = await evaluateInContext("SteamClient.Installs.OpenInstallWizard([\(id)], \"0\"); 'ok'")
            EventLog.shared.log(.window, "install wizard for app \(id) reopened in the Steam window")
        }
    }

    /// Whether an install goes ahead, after ``InstallWarning`` for a game
    /// with anti-cheat or an Unsupported verdict (only while the compatibility
    /// switch is on). A game set to its macOS version takes Steam for Mac's
    /// copy first.
    func confirmInstall(appID: Int) async -> Bool {
        guard await passesCompatibilityWarning(appID: appID) else { return false }
        await takeSteamForMacCopy(appID: appID)
        return true
    }

    /// Clones Steam for Mac's copy into the library (``SteamForMacCopy``)
    /// before Steam's wizard looks at the disk, only for a game set to its
    /// macOS version.
    private func takeSteamForMacCopy(appID: Int) async {
        guard Engine.running.supportsSteamPlayMacOS else { return }
        // Both sources: the page has details only for games whose page was
        // opened, and `config.vdf` lags a fresh mapping.
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

    /// Subscribes the context page to Steam's install wizard, posting
    /// `__installWizard` with `eInstallState` (0 when closed) and the app id.
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
