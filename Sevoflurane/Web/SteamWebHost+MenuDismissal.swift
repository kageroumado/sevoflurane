import AppKit

extension SteamWebHost {
    /// Closes a menu still visible 300 ms after a press outside it. Steam's
    /// notifications popover closes only on losing focus, which it never has
    /// here; real context menus are gone within the grace period.
    func installMenuDismissalGuard() {
        menuDismissalMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .keyDown],
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.chatPolicy.noteUserInteraction(at: .now)
                if event.type != .keyDown { self?.notePressOutsideMenus(event) }
            }
            return event
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
        ) { _ in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated { self?.closeMenusSurviving(after: .milliseconds(300)) }
            }
        }
    }

    private func notePressOutsideMenus(_ event: NSEvent) {
        let visibleMenus = popups.values.filter { $0.role == .menu && $0.isWindowVisible }
        guard !visibleMenus.isEmpty else { return }
        if let pressed = event.window, visibleMenus.contains(where: { $0.ownsWindow(pressed) }) {
            return
        }
        closeMenusSurviving(after: .milliseconds(300))
    }

    private func closeMenusSurviving(after grace: Duration) {
        Task(name: "Close stubborn menus") { [weak self] in
            try? await Task.sleep(for: grace)
            guard let self else { return }
            for menu in popups.values where menu.role == .menu && menu.isWindowVisible {
                // Steam's own dismissal also takes down the owner window's
                // click-catching overlay; closing is for a page that no
                // longer answers.
                if await menu.hideThroughSteam() {
                    try? await Task.sleep(for: .milliseconds(200))
                }
                guard menu.isWindowVisible else {
                    EventLog.shared.log(
                        .window,
                        "menu \(menu.name) survived an outside press — dismissed through Steam",
                    )
                    continue
                }
                EventLog.shared.log(
                    .window,
                    "menu \(menu.name) survived an outside press — closing it here",
                )
                menu.close()
            }
        }
    }
}
