import AppKit

/// The game's on-screen window, which `sevo app launch` reports back.
///
/// The frame is given in **points** (global display coordinates, origin
/// top-left of the primary display, y down, as `CGWindowListCopyWindowInfo`
/// reports and a click uses) and **pixels** (points × backing scale, what a
/// screenshot measures). A window left of or above the primary has a negative
/// origin; `off_primary` says so and `display` names its screen.
enum GameWindow {
    private static func area(of entry: [String: Any]) -> CGFloat {
        guard let bounds = entry[kCGWindowBounds as String] as? [String: Any],
              let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return 0 }
        return rect.width * rect.height
    }

    /// The largest on-screen, normal-level window of a game process, with its
    /// geometry; `nil` when none is up.
    static func current() -> [String: Any]? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Largest first: the frame-rate counter and a launcher can share the game's process.
        let sorted = list.sorted { area(of: $0) > area(of: $1) }
        let sessions = NativeSessions.live()
        for entry in sorted {
            guard entry[kCGWindowLayer as String] as? Int == 0,
                  let ownerName = entry[kCGWindowOwnerName as String] as? String,
                  let pid = entry[kCGWindowOwnerPID as String] as? pid_t,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? [String: Any],
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { continue }
            guard let program = WineWindowWatch.resolve(owner: ownerName, pid: pid, sessions: sessions),
                  program.isGame,
                  !WineWindowWatch.isOverlay(width: Int(bounds.width), height: Int(bounds.height))
            else { continue }
            let exe = program.name

            let (index, scale, displayTopLeft) = display(for: bounds)
            // kCGWindowName needs Screen Recording permission; empty without
            // it.
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

    /// The screen a top-left-origin rect's center sits on, its backing scale,
    /// and its frame in top-left space; the primary display otherwise.
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
        return (
            0,
            primary?.backingScaleFactor ?? 2,
            CGRect(x: f.minX, y: flip - f.maxY, width: f.width, height: f.height),
        )
    }
}
