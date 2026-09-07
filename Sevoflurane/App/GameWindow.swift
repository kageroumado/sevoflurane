import AppKit

/// The game's on-screen window, observed — what `sevo app launch` reports back
/// so an agent's model holds a real window, not "launch requested".
///
/// The frame is given twice on purpose: **points** (the Cocoa coordinate a
/// click or a move uses — origin top-left of the primary display, y down, the
/// same space `CGWindowListCopyWindowInfo` and rocuronium speak) and **pixels**
/// (points × the display's backing scale — what a screenshot measures). A
/// window on a display left of or above the primary has a negative origin;
/// `offPrimary` says so, and `display` names which screen it landed on.
enum GameWindow {
    /// The first on-screen, normal-level window owned by a game process — the
    /// same test `GameLaunchWatch` uses to decide "a game is up", plus the
    /// geometry. `nil` when no game window is on screen.
    static func current() -> [String: Any]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for entry in list {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let ownerName = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            guard let exe = WineWindowWatch.program(owner: ownerName, pid: pid),
                  exe.hasSuffix(".exe"),
                  !WineWindowWatch.gameInfrastructureOwners.contains(exe) else { continue }

            let (index, scale, displayTopLeft) = display(for: bounds)
            // kCGWindowName needs the Screen Recording permission; the app
            // holds it, so the title is usually here — empty when it is not.
            let title = entry[kCGWindowName as String] as? String ?? ""
            return [
                "window_id": id,
                "title": title,
                "owner": exe,
                "pid": Int(pid),
                "frame_points": rect(bounds),
                "frame_pixels": rect(bounds.applying(.init(scaleX: scale, y: scale))),
                "retina_scale": scale,
                "off_primary": bounds.minX < 0 || bounds.minY < 0,
                "display": ["index": index, "frame_points": rect(displayTopLeft)],
            ]
        }
        return nil
    }

    private static func rect(_ r: CGRect) -> [String: CGFloat] {
        ["x": r.minX, "y": r.minY, "w": r.width, "h": r.height]
    }

    /// The screen a top-left-origin window rect sits on, its backing scale,
    /// and that screen's own frame back in top-left space. Matches the window
    /// center so a window straddling an edge is attributed to where most of it
    /// is; falls back to the primary display.
    private static func display(for bounds: CGRect) -> (index: Int, scale: CGFloat, frameTopLeft: CGRect) {
        let flip = NSScreen.screens.first?.frame.maxY ?? 0
        let centreAppKit = CGPoint(x: bounds.midX, y: flip - bounds.midY)
        for (index, screen) in NSScreen.screens.enumerated() where screen.frame.contains(centreAppKit) {
            let f = screen.frame
            let topLeft = CGRect(x: f.minX, y: flip - f.maxY, width: f.width, height: f.height)
            return (index, screen.backingScaleFactor, topLeft)
        }
        let primary = NSScreen.screens.first
        let f = primary?.frame ?? .zero
        return (0, primary?.backingScaleFactor ?? 2,
                CGRect(x: f.minX, y: flip - f.maxY, width: f.width, height: f.height))
    }
}
