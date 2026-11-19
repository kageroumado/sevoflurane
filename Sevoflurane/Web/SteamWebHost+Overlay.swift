import AppKit

extension SteamWebHost {
    /// Whether the in-game overlay is up; popups opened meanwhile are
    /// non-activating panels so the game keeps focus.
    var isOverlayActive: Bool { overlayActive }

    /// The level of such a popup: the game's level + 2, above the overlay.
    /// `nil` when no overlay is up.
    var overlayChildLevel: Int? { overlayGame.map { $0.layer + 2 } }

    /// The overlay was toggled (``overlayScript``): shows it over the game's
    /// current frame (`WineWindowWatch.gameWindow`), or hides it and returns
    /// focus to the game.
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
            // Closed: Steam restores a child left open at the next activation.
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

    /// Closes the overlay through Steam, as "Back to Game" does; Steam's
    /// `RegisterForOverlayActivated(false)` then drives the hide.
    private func closeOverlay() {
        guard overlayActive, !overlayAppID.isEmpty else { return }
        let appID = overlayAppID
        Task(name: "Close Steam overlay") {
            _ = await evaluateInContext("SteamClient.Overlay.SetOverlayState(\(JSLiteral.string(appID)), 0)")
        }
    }

    /// The overlay holds key, so Shift+Tab lands in it instead of the game's
    /// hook; this swallows that chord and closes the overlay through Steam.
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

    /// Whether the overlay group belongs on screen: while active and while
    /// the game, or this app once the overlay has key, is frontmost.
    nonisolated static func overlayShouldShow(
        active: Bool, front: pid_t?, gamePID: pid_t?, ourPID: pid_t,
    ) -> Bool {
        // Unwrap first: with no front app and no game, `front == gamePID`
        // would be nil == nil and show a stuck overlay.
        guard active, let front else { return false }
        return front == gamePID || front == ourPID
    }

    /// Shows or hides the overlay and its children per
    /// ``overlayShouldShow(active:front:gamePID:ourPID:)``.
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

    /// Subscribes the context page to overlay activation, posted as
    /// `__overlayActivated`. The callback is Steam's
    /// `OnOverlayActivated(unPID, unAppID, bActive, …)`; the app id lets the
    /// host close the overlay with `SetOverlayState(appid, 0)`.
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
