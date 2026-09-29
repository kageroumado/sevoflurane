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
    ///
    /// A test run reads and writes a copy in its own home (``UserHome``).
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        adoptLegacyValues(into: defaults)
        return defaults
    }()

    /// The app's own domain, for what only the app reads: `standard`, or a
    /// copy in the test home for a test run, whose process runs under the
    /// shipping bundle identifier and would otherwise read the installed
    /// app's settings.
    nonisolated(unsafe) static let app: UserDefaults =
        UserHome.testDefaults(named: AppIdentity.identifierStem) ?? .standard

    /// Deliberately not the bundle identifier: `UserDefaults(suiteName:)`
    /// answers nil for the caller's own domain.
    private static let suiteName = "\(AppIdentity.identifierStem).shared"

    /// The suite's name, or its file in the test home for a test run.
    private static var domain: String {
        UserHome.isTestRun
            ? UserHome.url.appendingPathComponent("Library/Preferences/\(suiteName)").path
            : suiteName
    }

    /// Forgets every choice this app stored — the settings half of an
    /// uninstall, so a reinstall starts as a first run rather than inheriting
    /// a renderer, a bottle name and a pinned toolkit that no longer exist.
    static func reset() {
        shared.removePersistentDomain(forName: domain)
        shared.synchronize()
    }

    /// Keys that were written to the app's own domain before the suite
    /// existed, brought across the first time the suite is opened. Reading
    /// what the user last chose beats resetting them to the defaults.
    private static func adoptLegacyValues(into defaults: UserDefaults) {
        for key in ["managedRenderer", "managedMsync"]
            where defaults.object(forKey: key) == nil {
            guard let legacy = app.object(forKey: key) else { continue }
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

// MARK: - Community database

nonisolated extension Preferences {
    /// Whether closed runs go to the community database.
    /// `nil` until the user has been asked, which is what makes the question
    /// appear once and never again.
    static var sharesRunStats: Bool? {
        get { shared.object(forKey: sharesRunStatsKey) as? Bool }
        set { shared.set(newValue, forKey: sharesRunStatsKey) }
    }

    static let sharesRunStatsKey = "sharesRunStats"
}

// MARK: - Update channel

/// Which channel this Mac takes updates from, for the app and its engine
/// alike: GitHub releases and prereleases of Sevoflurane, and the engine
/// manifest's channel of the same name.
nonisolated enum UpdateChannel: String, CaseIterable, Sendable {
    /// Releases: what everyone gets once there is one.
    case stable
    /// Prereleases: what is being tried before it becomes a release. A Mac on
    /// beta takes the release when it is the newer of the two.
    case beta

    var label: String {
        let value = switch self {
        case .stable: "Release"
        case .beta: "Beta"
        }
        return InterfaceCopy.localized(value)
    }
}

nonisolated extension Preferences {
    /// Beta until the user picks Release: the release channel stays empty
    /// until there are betas enough people have run.
    static var updateChannel: UpdateChannel {
        get { updateChannel(stored: shared.string(forKey: updateChannelKey)) }
        set { shared.set(newValue.rawValue, forKey: updateChannelKey) }
    }

    /// The channel a stored value names; beta for nothing stored or a value
    /// this build does not know.
    static func updateChannel(stored: String?) -> UpdateChannel {
        stored.flatMap(UpdateChannel.init(rawValue:)) ?? .beta
    }

    /// Stays `engineChannel`: another key would drop the choice every Mac
    /// has stored.
    private static let updateChannelKey = "engineChannel"
}

// MARK: - Updates

nonisolated extension Preferences {
    /// When failing update checks were last written to the log. Every launch checks once, so a
    /// Mac that cannot reach the releases would otherwise say so at every boot.
    static var updateFailureLoggedAt: Date? {
        get { shared.object(forKey: "updateFailureLoggedAt") as? Date }
        set { shared.set(newValue, forKey: "updateFailureLoggedAt") }
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

    /// The games whose busy threads the app keeps quiet about: "Don't Ask for
    /// This Game" on the processor-limit offer (``ThreadSpinDiagnosis``).
    static let quietThreadSpinAppsKey = "quietThreadSpinApps"

    /// Whether a run of `appID` that kept many threads busy opens the offer to
    /// limit its processors.
    static func asksAboutThreadSpin(forApp appID: Int, in defaults: UserDefaults = shared) -> Bool {
        !(defaults.array(forKey: quietThreadSpinAppsKey) as? [Int] ?? []).contains(appID)
    }

    /// Keeps the processor-limit offer from opening for `appID` again.
    static func stopAskingAboutThreadSpin(forApp appID: Int, in defaults: UserDefaults = shared) {
        let quiet = defaults.array(forKey: quietThreadSpinAppsKey) as? [Int] ?? []
        guard !quiet.contains(appID) else { return }
        defaults.set(quiet + [appID], forKey: quietThreadSpinAppsKey)
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
