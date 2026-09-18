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

// MARK: - The Steam pages

nonisolated extension Preferences {
    /// Whether game pages carry the Mac compatibility strip. Off leaves
    /// Steam's own page exactly as the client draws it.
    static var compatibilityStrip: Bool {
        get { bool(forKey: "compatibilityStrip", default: true) }
        set { shared.set(newValue, forKey: "compatibilityStrip") }
    }
}

// MARK: - Discord

nonisolated extension Preferences {
    /// Whether the daemon starts the in-bottle relay after a client boot, so a
    /// game that ships its own Discord support reaches the Mac client.
    static var discordBridge: Bool {
        get { bool(forKey: "discordBridge", default: true) }
        set { shared.set(newValue, forKey: "discordBridge") }
    }

    /// Whether the app publishes the game it launched to Discord itself.
    static var discordPresence: Bool {
        get { bool(forKey: "discordPresence", default: true) }
        set { shared.set(newValue, forKey: "discordPresence") }
    }

    /// A boolean whose absence means something other than `false`.
    private static func bool(forKey key: String, default fallback: Bool) -> Bool {
        shared.object(forKey: key) as? Bool ?? fallback
    }
}

// MARK: - Crash reports

nonisolated extension Preferences {
    /// Whether a run that ends in a crash opens the offer to send a report.
    /// "Never ask again" on the prompt turns it off.
    static var asksAfterCrash: Bool {
        get { asksAfterCrash(in: shared) }
        set { shared.set(newValue, forKey: asksAfterCrashKey) }
    }

    static let asksAfterCrashKey = "asksAfterCrash"

    static func asksAfterCrash(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: asksAfterCrashKey) as? Bool ?? true
    }

    /// The token a sent report carries so two reports from one installation
    /// can be told apart on the receiving end. Random the first time it is
    /// asked for, then kept; it names nothing about the machine or the account.
    static var installToken: String {
        installToken(in: shared)
    }

    static let installTokenKey = "installToken"

    static func installToken(in defaults: UserDefaults) -> String {
        if let token = defaults.string(forKey: installTokenKey), !token.isEmpty { return token }
        let token = UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "")
        defaults.set(token, forKey: installTokenKey)
        return token
    }
}
