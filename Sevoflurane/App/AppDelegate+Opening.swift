import AppKit

extension AppDelegate {
    /// `steam://` links from browsers and other apps and `sevoflurane://play`
    /// from a game's Dock tile (CFBundleURLTypes), and
    /// Windows executables opened with Sevoflurane from Finder
    /// (CFBundleDocumentTypes).
    ///
    /// A link brings Steam's window up first, so the routed page has
    /// somewhere to land; an executable opens the adoption panel instead,
    /// which is the whole of what this app shows for a program of its own.
    func application(_: NSApplication, open urls: [URL]) {
        let programs = urls.filter(\.isFileURL)
        let links = urls.filter { $0.scheme?.lowercased() == "steam" }
        for url in urls where url.scheme?.lowercased() == "sevoflurane" {
            playFromDock(url)
        }
        // Steam is held behind an unfinished setup; the link has nowhere to
        // land yet, and the assistant is what gets it somewhere.
        if !links.isEmpty, setupWindow.show() {
            EventLog.shared.log(.window, "steam:// link while setup is unfinished — showing setup")
        } else if !links.isEmpty {
            host.showSteam()
            for url in links {
                host.executeSteamURL(url)
            }
        }
        for url in programs {
            openWindowsProgram(url)
        }
    }

    /// How long a Dock tile's launch waits for a client that is still coming
    /// up: a cold boot, with Steam's stores, takes a minute or two.
    private static let dockLaunchBudget = Duration.seconds(300)

    /// A game's Dock tile, opened: its loader handed the open to
    /// `sevoflurane://play/<id>`. The game starts the way its menu bar row
    /// starts it; a Steam game waits for a client that can take the launch,
    /// which is the whole of the wait when the tile also started this app.
    private func playFromDock(_ url: URL) {
        guard url.host() == "play", let id = Int(url.lastPathComponent) else { return }
        if setupWindow.show() {
            EventLog.shared.log(.window, "Dock tile for \(id) while setup is unfinished — showing setup")
            return
        }
        if AdoptedPrograms.isAdopted(id) {
            guard let entry = AdoptedPrograms.entry(id) else { return }
            EventLog.shared.log(.client, "Dock tile: starting \(entry.name)")
            (menuBarPopover?.quickLaunch ?? dockQuickLaunch).launch(entry)
            return
        }
        let name = host.libraryGames.first { $0.id == id }?.name
            ?? GameConfig.game(id).name ?? String(id)
        EventLog.shared.log(.client, "Dock tile: starting \(name)")
        // Steam for Mac starts a macOS build; no wait for the bottle's client.
        if MacBuildHandoff.take(appID: id, name: name) { return }
        Task(name: "Launch \(name) from the Dock") {
            let deadline = ContinuousClock.now + Self.dockLaunchBudget
            while supervisor.health != .healthy {
                guard ContinuousClock.now < deadline else {
                    EventLog.shared.log(.client, "Dock tile: \(name) not started, the client never came up")
                    return
                }
                try? await Task.sleep(for: .seconds(1))
            }
            ActivationPolicy.claimRightForALaunch()
            await supervisor.launch(appID: id, name: name)
        }
    }

    /// The Dock tile's menu (``DockMenu``), built anew each time the Dock
    /// asks for it, which keeps every change to it inside the moment the Dock
    /// reads it.
    func applicationDockMenu(_: NSApplication) -> NSMenu? {
        guard isRuntimeStarted, !setupWindow.isUnfinished else { return nil }
        let entries = DockMenu.entries(
            recentGames: host.recentGames,
            statuses: host.menuMirror?.friendsStatuses ?? [],
            clientIsReady: supervisor.health == .healthy,
        )
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in entries {
            menu.addItem(dockMenuItem(for: entry))
        }
        return menu
    }

    private func dockMenuItem(for entry: DockMenu.Entry) -> NSMenuItem {
        switch entry {
        case let .game(game):
            let item = NSMenuItem(
                title: game.name, action: #selector(playRecentGame(_:)), keyEquivalent: "",
            )
            item.target = self
            item.tag = game.id
            return item
        case let .destination(destination, isEnabled):
            let item = NSMenuItem(
                title: destination.title, action: #selector(openDockDestination(_:)), keyEquivalent: "",
            )
            item.target = self
            item.representedObject = destination
            item.isEnabled = isEnabled
            return item
        case let .friendsStatus(statuses, isEnabled):
            let item = NSMenuItem(title: String(localized: "Set Friends Status"), action: nil, keyEquivalent: "")
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for status in statuses {
                let row = NSMenuItem(
                    title: status.label, action: #selector(setFriendsStatus(_:)), keyEquivalent: "",
                )
                row.target = self
                row.representedObject = status
                row.state = status.isCurrent ? .on : .off
                row.isEnabled = status.isEnabled
                submenu.addItem(row)
            }
            item.submenu = submenu
            item.isEnabled = isEnabled
            return item
        case .separator:
            return .separator()
        }
    }

    @objc
    private func playRecentGame(_ item: NSMenuItem) {
        guard let game = host.recentGames.first(where: { $0.id == item.tag }) else { return }
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Launch \(game.name) from the Dock menu") { await supervisor.launch(game) }
    }

    @objc
    private func openDockDestination(_ item: NSMenuItem) {
        guard let destination = item.representedObject as? DockMenu.Destination else { return }
        EventLog.shared.log(.window, "Dock menu: \(destination.title)")
        guard let url = destination.steamURL else {
            host.openFriends()
            return
        }
        // The page opens in Steam's window, which comes up first so the route
        // has somewhere to land.
        host.showSteam()
        host.executeSteamURL(url)
    }

    @objc
    private func setFriendsStatus(_ item: NSMenuItem) {
        guard let status = item.representedObject as? SteamMenuMirror.StatusChoice else { return }
        EventLog.shared.log(.menu, "Dock menu: friends status \(status.label)")
        host.menuMirror?.setFriendsStatus(status)
    }

    /// Shows the adoption panel, or holds the program until the app is past
    /// setup and has a bottle to offer it.
    private func openWindowsProgram(_ url: URL) {
        guard isRuntimeStarted, !setupWindow.isUnfinished else {
            pendingPrograms.append(url)
            return
        }
        AdoptionPanel.shared.present(url)
    }

    /// Opens the panel for everything Finder handed over during launch.
    func openPendingPrograms() {
        let waiting = pendingPrograms
        pendingPrograms = []
        for url in waiting {
            AdoptionPanel.shared.present(url)
        }
    }

    /// The context page lives in a window of its own, so AppKit counts a
    /// visible window and its own reopen logic would never fire. `host`
    /// answers the question the user is actually asking.
    func applicationShouldHandleReopen(
        _: NSApplication,
        hasVisibleWindows appKitSeesWindows: Bool,
    ) -> Bool {
        // AppKit's own count of visible windows is in the line because it is
        // usually wrong here (parked pages and menus count) and its being
        // wrong the other way is what would make a Dock click do nothing.
        let seen = "AppKit counts \(appKitSeesWindows ? "visible windows" : "no visible window"), "
            + "policy \(NSApp.activationPolicy() == .regular ? "regular" : "accessory")"
        // Steam's windows are held behind an unfinished setup, so the window
        // a reopen can actually bring up is the assistant's.
        if setupWindow.show() {
            EventLog.shared.log(.window, "reopen request (Dock icon or Finder) — setup is unfinished; showing it (\(seen))")
            return true
        }
        EventLog.shared.log(
            .window,
            "reopen request (Dock icon or Finder) — Steam's window is "
                + "\(host.isSteamOnScreen ? "on screen; bringing it forward" : "hidden; showing it") (\(seen))",
        )
        host.showSteam()
        return true
    }
}
