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
            _ = await evaluateInContext("SteamClient.Installs.OpenInstallWizard([\(id)]); 'ok'")
            EventLog.shared.log(.window, "install wizard for app \(id) reopened in the Steam window")
        }
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
