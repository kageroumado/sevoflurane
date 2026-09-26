import AppKit
import IOKit

/// What the window server shows of a running game: whether its window is the one being
/// played, and the display it is on.
///
/// Read by the run meter every two seconds (``RunRecorder/sample(observing:)``). The game
/// is a process of its own to macOS, so "focused" is its process being the frontmost app
/// with a window on screen; the Steam overlay is a non-activating panel and leaves it so.
@MainActor
enum GameScreen {
    /// A window this small on either side is a splash, a tooltip or the frame time graph's
    /// card, never the surface being played; a window between this and
    /// ``MacHardware/minimumSide`` is a small game.
    static let smallestGameWindowSide: CGFloat = 128

    static func observe(pid: pid_t) -> GameObservation {
        let bounds = MacHardware.largestWindowBounds(ofPID: pid, minimumSide: smallestGameWindowSide)
        let displayID = bounds.flatMap { display(at: CGPoint(x: $0.midX, y: $0.midY)) }
        if isScreenLocked || CGDisplayIsAsleep(displayID ?? CGMainDisplayID()) != 0 {
            return GameObservation(focus: .asleep, display: displayID.map(describe))
        }
        guard let displayID else { return GameObservation(focus: .hidden, display: nil) }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        return GameObservation(focus: frontmost ? .focused : .background, display: describe(displayID))
    }

    /// A display's refresh rate, whether it varies it, and whether hardware is behind it.
    static func describe(_ id: CGDirectDisplayID) -> RunRecord.Display {
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id
        }
        let modeRate = CGDisplayCopyDisplayMode(id)?.refreshRate ?? 0
        let hz = modeRate > 0 ? modeRate : Double(screen?.maximumFramesPerSecond ?? 0)
        let variable = screen.map { $0.maximumRefreshInterval - $0.minimumRefreshInterval > 0.001 } ?? false
        return RunRecord.Display(refreshHz: (hz * 100).rounded() / 100, variable: variable, virtual: !hasHardware(id))
    }

    private static func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &id, &count) == .success, count > 0 else { return nil }
        return id
    }

    /// The session's screen is locked, or another user has the console.
    private static var isScreenLocked: Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
        return session["CGSSessionScreenIsLocked"] as? Bool == true
            || session[kCGSessionOnConsoleKey as String] as? Bool == false
    }

    // MARK: - Hardware behind a display

    /// Answers per display id, which a virtual display gets afresh each time it is made.
    private static var hardware: [CGDirectDisplayID: Bool] = [:]

    /// Whether a panel is behind the display: the built-in one, or a framebuffer whose
    /// EDID names the same vendor, product and serial as the display. A `CGVirtualDisplay`
    /// names whatever its maker chose and drives no framebuffer.
    private static func hasHardware(_ id: CGDirectDisplayID) -> Bool {
        if let known = hardware[id] { return known }
        let answer = CGDisplayIsBuiltin(id) != 0 || framebufferProducts().contains {
            matches($0, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id), serial: CGDisplaySerialNumber(id))
        }
        hardware[id] = answer
        return answer
    }

    /// Every framebuffer's `DisplayAttributes.ProductAttributes`, the panel's EDID identity.
    private static func framebufferProducts() -> [[String: Any]] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOMobileFramebuffer"), &iterator)
            == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var products: [[String: Any]] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            let value = IORegistryEntryCreateCFProperty(service, "DisplayAttributes" as CFString, kCFAllocatorDefault, 0)
            if let attributes = value?.takeRetainedValue() as? [String: Any],
               let product = attributes["ProductAttributes"] as? [String: Any] {
                products.append(product)
            }
        }
        return products
    }

    /// Whether a framebuffer's product attributes are this display's EDID identity. A serial
    /// is compared only when both sides have one; the built-in panel, whose `ProductID` is
    /// not its EDID code, never gets here (``hasHardware(_:)``).
    nonisolated static func matches(_ product: [String: Any], vendor: UInt32, model: UInt32, serial: UInt32) -> Bool {
        guard let productVendor = (product["LegacyManufacturerID"] as? NSNumber)?.uint32Value,
              let productID = (product["ProductID"] as? NSNumber)?.uint64Value,
              productVendor == vendor, productID == UInt64(model)
        else { return false }
        let productSerial = (product["SerialNumber"] as? NSNumber)?.uint32Value ?? 0
        return productSerial == 0 || serial == 0 || productSerial == serial
    }
}
