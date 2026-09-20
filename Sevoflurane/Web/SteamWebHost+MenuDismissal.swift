import AppKit

extension SteamWebHost {
    /// Steam dismisses its own menus, mostly. The notifications popover is
    /// the exception: on Windows it closes when its window loses focus, and
    /// here it never has focus to lose, so no click anywhere would ever close
    /// it. The guard restores the universal rule — a press outside a visible
    /// menu closes it — while giving Steam first right of refusal: a real
    /// context menu is gone well inside the grace period, and only a
    /// survivor is closed from this side.
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
                // Steam's own dismissal first: it takes the owner window's
                // click-catching overlay down with the menu. Closing the
                // window from here is the fallback for a menu whose page no
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
