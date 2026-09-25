import CoreGraphics
import Foundation
import IOKit

/// The facts about this Mac that decide how fast a game can run on it, each
/// one shared by every Mac of the same configuration: the model identifier,
/// the GPU's core count, and the memory tier.
nonisolated enum MacHardware {
    /// The chip's marketing name, like `Apple M3 Pro`.
    static let chip: String? = sysctlString("machdep.cpu.brand_string")

    /// `hw.model`, like `Mac15,8`: one identifier per model, never per machine.
    static let model: String? = sysctlString("hw.model")

    /// The GPU's core count, which splits configurations one chip name hides
    /// (an M3 Pro has 14 or 18). Read from the AGX accelerator's registry entry.
    static let gpuCores: Int? = {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let value = IORegistryEntryCreateCFProperty(service, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)
        return (value?.takeRetainedValue() as? NSNumber)?.intValue
    }()

    /// Installed memory in GB, rounded to the nearest size Apple sells, so the
    /// figure groups Macs rather than telling them apart.
    static let memoryGB: Int? = {
        var bytes: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0, bytes > 0 else { return nil }
        return memoryTier(bytes: bytes)
    }()

    static let memoryTiers = [8, 16, 18, 24, 32, 36, 48, 64, 96, 128, 192, 256, 512]

    static func memoryTier(bytes: UInt64) -> Int {
        let gigabytes = Double(bytes) / 1_073_741_824
        return memoryTiers.min { abs(Double($0) - gigabytes) < abs(Double($1) - gigabytes) } ?? 0
    }

    /// The largest on-screen window a process owns, in pixels: its bounds in
    /// points times the scale of the display it sits on.
    static func largestWindow(ofPID pid: pid_t) -> RunRecord.Pixels? {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        var largest: CGRect?
        for window in windows {
            guard (window[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary)
            else { continue }
            if rect.width * rect.height > (largest.map { $0.width * $0.height } ?? 0) {
                largest = rect
            }
        }
        guard let largest, largest.width >= minimumSide, largest.height >= minimumSide else { return nil }
        let scale = backingScale(at: CGPoint(x: largest.midX, y: largest.midY))
        return RunRecord.Pixels(
            width: Int((largest.width * scale).rounded()), height: Int((largest.height * scale).rounded()),
        )
    }

    /// Windows smaller than this on either side are splash screens and
    /// launchers, never the game's own surface.
    static let minimumSide: CGFloat = 320

    /// Pixels per point on the display under a point, from its current mode.
    private static func backingScale(at point: CGPoint) -> CGFloat {
        var display: CGDirectDisplayID = 0
        var count: UInt32 = 0
        guard CGGetDisplaysWithPoint(point, 1, &display, &count) == .success, count > 0,
              let mode = CGDisplayCopyDisplayMode(display), mode.width > 0
        else { return 1 }
        return CGFloat(mode.pixelWidth) / CGFloat(mode.width)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var value = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return String(decoding: value.prefix { $0 != 0 }, as: UTF8.self)
    }
}
