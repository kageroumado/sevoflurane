import AppKit

extension SteamWebHost {
    /// Whether Steam's desktop window is visible on some screen. Use this
    /// over `NSApp.windows` or a reopen's `hasVisibleWindows`, which count the
    /// context page, faded menus and parked toasts.
    var isSteamOnScreen: Bool {
        guard let desktop, desktop.isWindowVisible else { return false }
        return SteamScreenSpace.isOnSomeScreen(desktop.appKitFrame)
    }

    /// Logs the window inventory on every adoption and close in debug mode.
    /// Closed menus, a dozen per window, are only counted.
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
