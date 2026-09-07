import Foundation

/// Files the app bundle ships in `Contents/Resources`, by name — the
/// greenworks preload, the shader packages directory.
///
/// `sevo` lives in the same bundle's `Contents/Helpers`, where `Bundle.main`
/// may resolve to the helper directory rather than the app, so the bundle's
/// `Contents` is found by walking up from the executable when the direct
/// lookup misses. `nil` from a bundle without the file, and from a `sevo`
/// built outside any bundle.
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
