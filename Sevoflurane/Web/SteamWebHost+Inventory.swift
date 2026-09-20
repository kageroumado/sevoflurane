import AppKit

extension SteamWebHost {
    /// Whether Steam's own window is somewhere a person can see it.
    ///
    /// AppKit's answer to the same question is worthless here: the context
    /// page, faded menus and parked toasts are all ordered in without being
    /// on any screen, so `NSApp.windows` and the `hasVisibleWindows` a reopen
    /// carries both say yes when the user is looking at nothing. This is the
    /// one answer the app acts on.
    var isSteamOnScreen: Bool {
        guard let desktop, desktop.isWindowVisible else { return false }
        return SteamScreenSpace.isOnSomeScreen(desktop.appKitFrame)
    }

    /// The inventory as a log line, written on every adoption and close while
    /// debug mode is on. `GET /windows` answers the same question, but only
    /// for someone who thought to ask it while the window was still there;
    /// this is what a report has afterwards.
    ///
    /// A closed menu is counted rather than described: Steam keeps a dozen of
    /// them per window, they are hidden two-by-one points at the pointer, and
    /// spelling them all out on every adoption is what would make this
    /// unreadable.
    func logWindowInventory(_ occasion: String) {
        guard DebugModeSwitch.shared.isOn else { return }
        var rows: [String] = []
        var hiddenMenus = 0
        for row in windowInventory() {
            let visible = row["visible"] as? Bool == true
            let role = row["role"] as? String ?? "?"
            guard visible || role != "menu" else {
                hiddenMenus += 1
                continue
            }
            let name = row["name"] as? String ?? "?"
            rows.append(
                "\(name) [\(role)] \(visible ? "visible" : "hidden") \(row["frame"] as? String ?? "")",
            )
        }
        if hiddenMenus > 0 { rows.append("\(hiddenMenus) closed menus") }
        EventLog.shared.log(
            .window,
            "windows after \(occasion): \(rows.isEmpty ? "none" : rows.joined(separator: "; "))",
        )
    }

    /// Every window the host owns, for `sevo` diagnostics
    /// (control endpoint `GET /windows`).
    func windowInventory() -> [[String: Any]] {
        var rows: [[String: Any]] = []
        if let contextWindow {
            rows.append([
                "name": "SharedJSContext",
                "role": "context",
                "frame": NSStringFromRect(contextWindow.frame),
                "visible": contextWindow.isVisible,
            ])
        }
        for popup in popups.values {
            rows.append([
                "name": popup.name,
                "role": String(describing: popup.role),
                "frame": NSStringFromRect(popup.appKitFrame),
                "visible": popup.isWindowVisible,
            ])
        }
        return rows
    }
}
