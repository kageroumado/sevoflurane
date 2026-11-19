import Foundation

/// Files in the app's `Contents/Resources`, by name. For `sevo` in
/// `Contents/Helpers`, `Bundle.main` can miss them, so `Contents` is found by
/// walking up from the executable.
nonisolated enum BundledResources {
    static func url(_ name: String) -> URL? {
        let manager = FileManager.default
        if let direct = Bundle.main.resourceURL?.appendingPathComponent(name),
           manager.fileExists(atPath: direct.path) { return direct }
        var directory = Bundle.main.executableURL?
            .resolvingSymlinksInPath().deletingLastPathComponent()
        while let current = directory, current.path != "/" {
            if current.lastPathComponent == "Contents" {
                let candidate = current.appendingPathComponent("Resources/\(name)")
                return manager.fileExists(atPath: candidate.path) ? candidate : nil
            }
            directory = current.deletingLastPathComponent()
        }
        return nil
    }
}
