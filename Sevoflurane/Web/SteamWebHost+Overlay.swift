import AppKit

extension SteamWebHost {
    /// Whether the in-game overlay is up. A popup Steam opens while it is (the
    /// overlay's Settings, its dialogs) is built as a non-activating panel and
    /// shown without activating the app, so clicking it never pulls focus off
    /// the game — the drop that puts the Dock between the game and the overlay
    /// and breaks Shift+Tab.
    var isOverlayActive: Bool { overlayActive }

    /// The level such a popup sits at: above the overlay (the game's level + 1),
    /// so it is not hidden behind it. `nil` when no overlay is up.
    var overlayChildLevel: Int? { overlayGame.map { $0.layer + 2 } }

    /// The in-game overlay was activated or dismissed (Shift+Tab), told by the
    /// context page's subscription (``overlayScript``). Places the overlay
    /// window over the running game and fades it in, or fades it out and hands
    /// focus back to the game process. The game window's frame comes from
    /// CGWindowList (`WineWindowWatch.gameWindow`), so a game that moved or
    /// resized since launch is followed on the next activation.
    func noteOverlayActivated(active: Bool, appID: String) {
        guard let overlay = popups.values.first(where: { $0.role == .gameOverlay }) else {
            EventLog.shared.log(
                .window,
                "overlay \(active ? "activated" : "dismissed"), but no overlay window is adopted",
            )
            return
        }
        overlayActive = active
        guard active else {
            removeOverlayFrontObserver()
            removeOverlayKeyMonitor()
            overlay.hideOverlay()
            // Closed, not merely hidden: a child left open is one Steam
            // restores at the next activation and at the next game start.
            for child in overlayChildren {
                child.close()
            }
            overlayChildren.removeAll()
            if let pid = overlayGame?.pid {
                Task(name: "Return focus to the game") {
                    await Activation().bringForward(pid: pid, describedAs: "the game behind the overlay")
                    ActivationPolicy.recedeIfLastWindow(closing: nil)
                }
            }
            overlayGame = nil
            EventLog.shared.log(.window, "overlay dismissed; focus returned to the game")
            return
        }
        overlayAppID = appID
        Task(name: "Show Steam overlay") { [weak self] in
            let game = await WineWindowWatch.gameWindow()
            guard let self, overlayActive else { return }
            overlayGame = game
            installOverlayFrontObserver(overlay)
            installOverlayKeyMonitor()
            applyOverlayPresence(overlay)
            EventLog.shared.log(
                .window,
                "overlay activated over the game "
                    + "(\(game.map { "pid \($0.pid), level \($0.layer)" } ?? "no game window found"))",
            )
        }
    }

    /// Closes the overlay the way its own "Back to Game" does — through Steam,
    /// so the client's overlay state stays in step with ours. It answers with
    /// `RegisterForOverlayActivated(false)`, which drives the hide and returns
    /// focus to the game.
    private func closeOverlay() {
        guard overlayActive, !overlayAppID.isEmpty else { return }
        let appID = overlayAppID
        Task(name: "Close Steam overlay") {
            _ = await evaluateInContext("SteamClient.Overlay.SetOverlayState(\"\(appID)\", 0)")
        }
    }

    /// While the overlay is up it holds key (so its chat and search take the
    /// keyboard), which means Shift+Tab — the toggle that would close it —
    /// lands in the overlay panel instead of the game's hook. This swallows
    /// that one chord and closes the overlay through Steam.
    private func installOverlayKeyMonitor() {
        removeOverlayKeyMonitor()
        overlayKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let swallow = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.overlayActive,
                      event.keyCode == 48, event.modifierFlags.contains(.shift)
                else { return false }
                self.closeOverlay()
                return true
            }
            return swallow ? nil : event
        }
    }

    private func removeOverlayKeyMonitor() {
        if let overlayKeyMonitor {
            NSEvent.removeMonitor(overlayKeyMonitor)
            self.overlayKeyMonitor = nil
        }
    }

    /// Shows the overlay at the game's frame and level only while the game — or
    /// this app, once the overlay has key — is frontmost; hides it whenever a
    /// third application is, so the overlay travels with the game and never
    /// covers anything else.
    /// Whether the overlay group belongs on screen: only while active and while
    /// the game — or this app, once the overlay has taken key — is the
    /// frontmost application. Any other app in front (one the user switched to,
    /// or a window that raised itself) takes the overlay off screen with it.
    nonisolated static func overlayShouldShow(
        active: Bool, front: pid_t?, gamePID: pid_t?, ourPID: pid_t,
    ) -> Bool {
        // `let front` first: with no frontmost app, and none reported, a bare
        // `front == gamePID` would be nil == nil == true and show a stuck
        // overlay over the desktop when no game was even found.
        guard active, let front else { return false }
        return front == gamePID || front == ourPID
    }

    private func applyOverlayPresence(_ overlay: SteamWindow) {
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let ours = ProcessInfo.processInfo.processIdentifier
        let shown = Self.overlayShouldShow(
            active: overlayActive, front: front, gamePID: overlayGame?.pid, ourPID: ours,
        )
        if shown {
            let frame: NSRect? = overlayGame.map { window in
                NSRect(
                    origin: SteamScreenSpace.appKitOrigin(
                        steamX: window.bounds.minX,
                        steamY: window.bounds.minY,
                        size: window.bounds.size,
                    ),
                    size: window.bounds.size,
                )
            }
            overlay.showOverlay(frame: frame, level: overlayGame.map { $0.layer + 1 })
        } else {
            overlay.hideOverlay()
        }
        // The children ride with the overlay: hidden when it is, shown when it
        // returns (a closed one's window is gone, so this no-ops for it).
        for child in overlayChildren {
            child.setOrderedIn(shown)
        }
    }

    private func installOverlayFrontObserver(_ overlay: SteamWindow) {
        removeOverlayFrontObserver()
        overlayFrontObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main,
        ) { [weak self, weak overlay] _ in
            MainActor.assumeIsolated {
                guard let self, let overlay else { return }
                self.applyOverlayPresence(overlay)
            }
        }
    }

    private func removeOverlayFrontObserver() {
        if let overlayFrontObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(overlayFrontObserver)
            self.overlayFrontObserver = nil
        }
    }

    /// Subscribes the context page to the client's overlay activation. The
    /// callback is Steam's own `OnOverlayActivated(unPID, unAppID, bActive, …)`
    /// (its handler does `GetOverlayInstance(appid, pid)` then, for a desktop
    /// overlay, `SetIsOverlayActive(bActive)`): the second argument is the
    /// app id, the third the shown flag. Both come back through the popup
    /// message handler as `__overlayActivated`; the app id lets the host close
    /// the overlay the way "Back to Game" does, `SetOverlayState(appid, 0)`.
    /// Re-registered on reload.
    static let overlayScript = """
    (function () {
      if (window.__sevoOverlay) return "already registered";
      if (!window.SteamClient || !SteamClient.Overlay
          || !SteamClient.Overlay.RegisterForOverlayActivated) return "unavailable";
      window.__sevoOverlay = true;
      SteamClient.Overlay.RegisterForOverlayActivated(function (pid, appid, active) {
        try {
          window.webkit.messageHandlers.sevoWindow.postMessage(
            { fn: "__overlayActivated", args: [active ? 1 : 0, String(appid || "")] });
        } catch (e) {}
      });
      return "registered";
    })()
    """
}
