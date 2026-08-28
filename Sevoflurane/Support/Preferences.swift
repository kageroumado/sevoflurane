import Foundation

/// The defaults the app and the `sevo` CLI both read.
///
/// `UserDefaults.standard` is per-process: the app writes into its bundle's
/// domain and the CLI into its own, so anything stored there is invisible to
/// the other face of the same installation — the CLI would configure one
/// bottle's graphics while the app configured another's. Everything the two
/// must agree on lives in one suite instead.
nonisolated enum Preferences {
    /// `UserDefaults` is thread-safe by contract and predates `Sendable`; the
    /// suite is opened once and only ever read and written through it.
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        adoptLegacyValues(into: defaults)
        return defaults
    }()

    /// Deliberately not the bundle identifier: `UserDefaults(suiteName:)`
    /// answers nil for the caller's own domain.
    private static let suiteName = "glass.kagerou.sevoflurane.shared"

    /// Forgets every choice this app stored — the settings half of an
    /// uninstall, so a reinstall starts as a first run rather than inheriting
    /// a renderer, a bottle name and a pinned toolkit that no longer exist.
    static func reset() {
        shared.removePersistentDomain(forName: suiteName)
        shared.synchronize()
    }

    /// Keys that were written to the app's own domain before the suite
    /// existed, brought across the first time the suite is opened. Reading
    /// what the user last chose beats resetting them to the defaults.
    private static func adoptLegacyValues(into defaults: UserDefaults) {
        for key in ["managedRenderer", "managedMsync"]
            where defaults.object(forKey: key) == nil {
            guard let legacy = UserDefaults.standard.object(forKey: key) else { continue }
            defaults.set(legacy, forKey: key)
        }
    }
}
