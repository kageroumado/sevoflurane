import Foundation

extension SteamWebHost {
    /// The context boots its window on no route at all, the same way a
    /// `-silent` client does until its tray item is clicked. The route runs
    /// through Steam's own navigator in this page — `ExecuteSteamURL` would
    /// navigate the window the *bottle's* client owns instead.
    ///
    /// Answers whether the route was taken. It is refused while the page is
    /// still booting: `Home()` runs `ExitSearch → ResetSearch → SetIsCollapsed`
    /// against the collection store, which the navigator's own existence says
    /// nothing about.
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

    /// How long a route waits for the page to be ready, and how often it
    /// asks — the bounded poll ``repairBlankDesktop`` runs on, at the pace a
    /// user notices a window that is still black.
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

    /// The retry itself. A page that never becomes ready says so once: the
    /// window stays on no route, which ``repairBlankDesktop`` is the backstop
    /// for.
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

    /// A window is about to reach the screen.
    ///
    /// The desktop is the one that needs a word first. Steam boots its window
    /// on no route, so one that arrives on screen without having been
    /// navigated is chrome over black: the nav bar and the footer render and
    /// everything between them is empty. ``showSteam`` routes the window it
    /// opens; a window Steam puts up itself reaches the screen through here
    /// instead, which is what an app relaunched onto a live client, or a
    /// client that came back on its own, gives the user.
    func noteWindowWillShow(_ window: SteamWindow) {
        guard window.role == .desktop, !clientIsStopping else { return }
        guard hasRoutedDesktop else {
            routeDesktop()
            return
        }
        repairBlankDesktop()
    }

    /// Sends a desktop that is showing no route back to the library.
    ///
    /// The blank state reads the same from the page whatever put it there:
    /// the element under the middle of the window is the container the route
    /// would render into, filling the space between the header and the
    /// footer, because nothing is painted over it. The store reads the same
    /// way, since its content is a native child view rather than page
    /// content, so a visible BrowserView stands the check down — and because
    /// one that is still arriving would be missed, the reading has to hold
    /// across two samples a second apart before anything moves.
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
