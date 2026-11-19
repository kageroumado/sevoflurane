import Foundation

extension SteamWebHost {
    /// Routes the desktop window to the library through this page's own
    /// navigator (`ExecuteSteamURL` would navigate the bottle client's
    /// window). Refused while booting: `Home()` runs
    /// `ExitSearch → ResetSearch → SetIsCollapsed` against the collection
    /// store, which may not exist yet. Answers whether the route was taken.
    func openLibrary() async -> Bool {
        await evaluateInContext("""
        (function () {
          if (!window.__sevoIsReady || !__sevoIsReady()) return "false";
          var window_ = window.SteamUIStore && SteamUIStore.WindowStore
            && SteamUIStore.WindowStore.MainWindowInstance;
          var nav = window_ && window_.Navigator;
          if (!nav || typeof nav.Home !== "function") return "false";
          nav.Home();
          return "true";
        })()
        """) == "true"
    }

    /// The bounded poll for a ready page: 40 tries, 250 ms apart.
    private enum Routing {
        static let attempts = 40
        static let interval: Duration = .milliseconds(250)
    }

    /// Sends the desktop to the library, retrying while the page's stores
    /// are still arriving.
    func routeDesktop() {
        Task(name: "Route the desktop to the library") { [weak self] in
            await self?.routeDesktopWhenReady()
        }
    }

    /// A page that never becomes ready is logged once; ``repairBlankDesktop``
    /// is the backstop.
    private func routeDesktopWhenReady() async {
        guard !isRoutingDesktop else { return }
        isRoutingDesktop = true
        defer { isRoutingDesktop = false }
        for _ in 0 ..< Routing.attempts {
            if await openLibrary() {
                hasRoutedDesktop = true
                return
            }
            try? await Task.sleep(for: Routing.interval)
        }
        EventLog.shared.log(
            .window, "Steam's stores never finished booting — the desktop is on no route",
        )
    }

    /// A window is about to reach the screen. A desktop window Steam shows on
    /// its own (an app relaunched onto a live client) may be on no route,
    /// which renders as chrome over black, so it is routed here.
    func noteWindowWillShow(_ window: SteamWindow) {
        guard window.role == .desktop, !clientIsStopping else { return }
        guard hasRoutedDesktop else {
            routeDesktop()
            return
        }
        repairBlankDesktop()
    }

    /// Sends a desktop showing no route back to the library. Blank means the
    /// element under the window's middle is the route container itself. The
    /// store reads the same (its content is a native view), so a visible
    /// BrowserView stands the check down, and the reading must hold across
    /// two samples a second apart.
    func repairBlankDesktop() {
        Task(name: "Repair a blank desktop") { [weak self] in
            for _ in 0 ..< 2 {
                try? await Task.sleep(for: .seconds(1))
                guard let self, let desktop, desktop.isWindowVisible,
                      !desktop.browserViewStatuses.contains(where: \.visible),
                      await evaluateInContext(
                          Self.blankDesktopScript(desktop: desktop.name),
                      ) == "blank"
                else { return }
            }
            guard let self else { return }
            EventLog.shared.log(
                .window, "the desktop was showing no route — sent it back to the library",
            )
            await routeDesktopWhenReady()
        }
    }

    private static func blankDesktopScript(desktop name: String) -> String {
        """
        (function () {
          try {
            var popups = window.g_PopupManager && g_PopupManager.m_mapPopups;
            var entry = popups && popups.get(\(JSLiteral.string(name)));
            var win = entry && entry.m_popup;
            if (!win || win.closed) return "";
            var el = win.document.elementFromPoint(
              Math.round(win.innerWidth / 2), Math.round(win.innerHeight / 2));
            if (!el) return "";
            var rect = el.getBoundingClientRect();
            var fillsTheContentArea = rect.width >= win.innerWidth * 0.9
              && rect.height >= win.innerHeight * 0.6;
            return fillsTheContentArea ? "blank" : "";
          } catch (e) {
            return "error: " + e;
          }
        })()
        """
    }
}
