import Foundation

/// Translates the bottle's Windows paths into macOS paths.
///
/// Steam hands out paths like `C:\Program Files (x86)\Steam\steamapps\common\…`;
/// what actually exists is the bottle's `drive_c`. The drive letters are
/// resolved through the bottle's own `dosdevices` symlinks (`c:` → `../drive_c`,
/// `z:` → `/`), so any mapping CrossOver knows about is honored without a
/// hardcoded table.
enum WinePath {
    static let bottle = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles/Steam")

    static func macURL(fromWindowsPath path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2,
              normalized[normalized.index(after: normalized.startIndex)] == ":" else {
            // Already a POSIX path (Steam under Proton reports those too).
            return normalized.hasPrefix("/") ? URL(fileURLWithPath: normalized) : nil
        }
        let letter = String(normalized.prefix(1)).lowercased()
        let device = bottle.appendingPathComponent("dosdevices/\(letter):")
        let root = device.resolvingSymlinksInPath()
        let rest = String(normalized.dropFirst(2)).trimmingCharacters(in: ["/"])
        let target = rest.isEmpty ? root : root.appendingPathComponent(rest)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }
}
