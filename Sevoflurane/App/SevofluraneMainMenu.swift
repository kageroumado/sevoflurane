import AppKit

/// Builds the app's menu bar.
///
/// A menu-bar-only app has no menu bar until one of Steam's windows promotes
/// it to a regular app. This is also the load-bearing half of hosting a web
/// view:
/// WebKit routes ⌘C, ⌘V and friends through the responder chain, so text
/// editing anywhere in Steam's UI only works if an Edit menu claims those keys.
enum SevofluraneMainMenu {
    /// Steam's strip order (Steam, View, Friends, Games) sits between the app
    /// menu and Edit; Steam's Help becomes the macOS Help menu. The app's own
    /// View items ride at the bottom of the mirrored View menu.
    static func install(mirror: SteamMenuMirror) {
        let main = NSMenu()
        main.addItem(submenu(appMenu(), title: "Sevoflurane"))
        for title in SteamMenuMirror.rootTitles where title != "Help" {
            main.addItem(submenu(mirror.menu(for: title), title: title))
        }
        appendNativeViewItems(to: mirror.menu(for: "View"))
        main.addItem(submenu(editMenu(), title: "Edit"))
        main.addItem(submenu(windowMenu(), title: "Window"))
        #if DEBUG
            main.addItem(submenu(debugMenu(), title: "Debug"))
        #endif
        main.addItem(submenu(mirror.menu(for: "Help"), title: "Help"))
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.item(withTitle: "Window")?.submenu
        NSApp.helpMenu = mirror.menu(for: "Help")
    }

    private static func submenu(_ menu: NSMenu, title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        menu.title = title
        item.submenu = menu
        return item
    }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "About Sevoflurane",
            action: #selector(AppDelegate.showAbout(_:)),
            keyEquivalent: "",
        )
        // Titled by `AppDelegate.validateMenuItem(_:)`: "Install Update …" once one is out.
        menu.addItem(
            withTitle: "Check for Updates…",
            action: #selector(AppDelegate.checkForUpdates(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        // No ⌘, here: in this app that shortcut belongs to Steam ▸ Settings,
        // which is the settings window a user of a Steam client means.
        menu.addItem(
            withTitle: "Sevoflurane Settings…",
            action: #selector(AppDelegate.showSettings(_:)),
            keyEquivalent: "",
        )
        // Checked by `AppDelegate.validateMenuItem(_:)`, so it reads the
        // switch however it was last flipped.
        menu.addItem(
            withTitle: InterfaceCopy.localized("Streamer Mode"),
            action: #selector(AppDelegate.toggleStreamerMode(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())

        let services = NSMenu()
        let servicesItem = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        menu.addItem(servicesItem)
        NSApp.servicesMenu = services
        menu.addItem(.separator())

        menu.addItem(
            withTitle: "Hide Sevoflurane",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h",
        )
        let hideOthers = menu.addItem(
            withTitle: "Hide Others",
            action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h",
        )
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        menu.addItem(
            withTitle: "Show All",
            action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Sevoflurane",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q",
        )
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = menu.addItem(
            withTitle: "Redo",
            action: Selector(("redo:")),
            keyEquivalent: "z",
        )
        redo.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x",
        )
        menu.addItem(
            withTitle: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c",
        )
        menu.addItem(
            withTitle: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v",
        )
        menu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a",
        )
        return menu
    }

    /// The app's own View commands, appended after the mirrored section. The
    /// tag keeps ``SteamMenuMirror`` from sweeping them on refresh.
    private static func appendNativeViewItems(to menu: NSMenu) {
        let separator = NSMenuItem.separator()
        separator.tag = SteamMenuMirror.nativeTag
        menu.addItem(separator)
        let reload = menu.addItem(
            withTitle: "Reload Steam UI",
            action: #selector(AppDelegate.reloadSteamUI(_:)),
            keyEquivalent: "r",
        )
        reload.tag = SteamMenuMirror.nativeTag
        let fullScreen = menu.addItem(
            withTitle: "Enter Full Screen",
            action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f",
        )
        fullScreen.keyEquivalentModifierMask = [.command, .control]
        fullScreen.tag = SteamMenuMirror.nativeTag
    }

    #if DEBUG
        /// The onboarding harness (`SetupDryRun.swift`): one item per scenario,
        /// each opening the wizard against that fixture machine.
        private static func debugMenu() -> NSMenu {
            let menu = NSMenu()
            menu.addItem(
                withTitle: "UI Gallery",
                action: #selector(AppDelegate.showGallery(_:)),
                keyEquivalent: "",
            )
            let dryRun = NSMenu()
            let dryRunItem = NSMenuItem(
                title: "Onboarding Dry Run", action: nil, keyEquivalent: "",
            )
            dryRunItem.submenu = dryRun
            menu.addItem(dryRunItem)
            for scenario in SetupScenario.allCases {
                let item = dryRun.addItem(
                    withTitle: scenario.title,
                    action: #selector(AppDelegate.runOnboardingDryRun(_:)),
                    keyEquivalent: "",
                )
                item.representedObject = scenario.rawValue
            }
            return menu
        }
    #endif

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(
            withTitle: "Minimize",
            action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m",
        )
        menu.addItem(
            withTitle: "Zoom",
            action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "",
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w",
        )
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Reports",
            action: #selector(AppDelegate.showReports(_:)),
            keyEquivalent: "",
        )
        menu.addItem(
            withTitle: "Processes",
            action: #selector(AppDelegate.showProcesses(_:)),
            keyEquivalent: "",
        )
        menu.addItem(
            withTitle: "Bring All to Front",
            action: #selector(NSApplication.arrangeInFront(_:)),
            keyEquivalent: "",
        )
        return menu
    }
}
