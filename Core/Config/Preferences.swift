import Foundation

/// The defaults the app and the `sevo` CLI both read.
///
/// `UserDefaults.standard` is per process, so anything the app and CLI must
/// agree on lives in this one suite.
nonisolated enum Preferences {
    /// `nonisolated(unsafe)`: `UserDefaults` is thread-safe. A test run uses a
    /// copy in its own home (``UserHome``).
    nonisolated(unsafe) static let shared: UserDefaults = {
        let defaults = UserDefaults(suiteName: domain) ?? .standard
        adoptLegacyValues(into: defaults)
        return defaults
    }()

    /// The app's own domain, or a test-home copy so a test run does not read
    /// the installed app's settings.
    nonisolated(unsafe) static let app: UserDefaults =
        UserHome.testDefaults(named: AppIdentity.identifierStem) ?? .standard

    /// Never the bundle identifier: `UserDefaults(suiteName:)` answers nil
    /// for the caller's own domain.
    private static let suiteName = "\(AppIdentity.identifierStem).shared"

    /// The suite's name, or its file in the test home for a test run.
    private static var domain: String {
        UserHome.isTestRun
            ? UserHome.url.appendingPathComponent("Library/Preferences/\(suiteName)").path
            : suiteName
    }

    /// The app's own domain: its bundle identifier, or its file in the test
    /// home for a test run.
    private static var appDomain: String {
        UserHome.isTestRun
            ? UserHome.url.appendingPathComponent("Library/Preferences/\(AppIdentity.identifierStem)").path
            : Bundle.main.bundleIdentifier ?? AppIdentity.identifierStem
    }

    /// Forgets every stored choice, so a reinstall starts as a first run.
    static func reset() {
        reset(suite: shared, named: domain, app: app, named: appDomain)
    }

    /// Empties the suite and the app's own domain: left in place, the app's
    /// domain is where ``adoptLegacyValues(into:)`` copies old keys back from.
    static func reset(suite: UserDefaults, named suiteDomain: String, app: UserDefaults, named appDomain: String) {
        suite.removePersistentDomain(forName: suiteDomain)
        suite.synchronize()
        app.removePersistentDomain(forName: appDomain)
        app.synchronize()
    }

    /// Copies keys the suite lacks from the app's own domain, where older
    /// installs wrote them, the first time the suite is opened.
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
    /// Whether game pages carry the Mac compatibility strip.
    static var compatibilityStrip: Bool {
        get { bool(forKey: "compatibilityStrip", default: true) }
        set { shared.set(newValue, forKey: "compatibilityStrip") }
    }

    /// Whether the stylesheets in the Styles folder style Steam's windows.
    static var userStyles: Bool {
        get { bool(forKey: "userStyles", default: false) }
        set { shared.set(newValue, forKey: "userStyles") }
    }

    /// Whether the Styles folder also styles the store and community pages,
    /// while ``userStyles`` is on.
    static var userStylesOnWebPages: Bool {
        get { bool(forKey: "userStylesOnWebPages", default: false) }
        set { shared.set(newValue, forKey: "userStylesOnWebPages") }
    }
}

// MARK: - Community database

nonisolated extension Preferences {
    /// Whether closed runs go to the community database; `nil` until asked.
    static var sharesRunStats: Bool? {
        get { shared.object(forKey: sharesRunStatsKey) as? Bool }
        set { shared.set(newValue, forKey: sharesRunStatsKey) }
    }

    static let sharesRunStatsKey = "sharesRunStats"
}

// MARK: - Updates

nonisolated extension Preferences {
    /// When failing update checks were last logged, so an offline Mac does not
    /// log one every launch.
    static var updateFailureLoggedAt: Date? {
        get { shared.object(forKey: "updateFailureLoggedAt") as? Date }
        set { shared.set(newValue, forKey: "updateFailureLoggedAt") }
    }

    /// The highest build number this installation has run, for
    /// ``noteBuild(_:)``.
    static var highestBuildRun: Int {
        get { shared.integer(forKey: "highestBuildRun") }
        set { shared.set(newValue, forKey: "highestBuildRun") }
    }

    /// Records the running build and answers the newer one it replaced, if
    /// any. The updater checks who signed an update and never which build it
    /// is, so an old signed build offered under a new tag would install; this
    /// is where that shows.
    static func noteBuild(_ build: Int) -> Int? {
        let highest = highestBuildRun
        guard build < highest else {
            highestBuildRun = build
            return nil
        }
        return highest
    }

    /// Whether the person was told that Steam here signs out while Steam for
    /// Mac uses the same account.
    static var toldAboutSteamForMacSession: Bool {
        get { bool(forKey: "toldAboutSteamForMacSession", default: false) }
        set { shared.set(newValue, forKey: "toldAboutSteamForMacSession") }
    }

    /// Whether a game's Play setting offers Steam for Mac
    /// (``NativeSteam/isOffered``).
    static var offersSteamForMac: Bool {
        get { bool(forKey: "offersSteamForMac", default: false) }
        set { shared.set(newValue, forKey: "offersSteamForMac") }
    }
}

// MARK: - Discord

nonisolated extension Preferences {
    /// Whether the daemon starts the in-bottle Discord relay after a client boot.
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

// MARK: - Fixes

nonisolated extension Preferences {
    /// Whether a game's first launch takes the fix list's values for unset
    /// settings (``FixLedger``).
    static var appliesKnownFixes: Bool {
        get { shared.object(forKey: "appliesKnownFixes") as? Bool ?? true }
        set { shared.set(newValue, forKey: "appliesKnownFixes") }
    }

    /// The highest fix list serial taken; a lower one is refused as a replay.
    static var fixListSerial: Int {
        get { shared.integer(forKey: "fixListSerial") }
        set { shared.set(newValue, forKey: "fixListSerial") }
    }
}

// MARK: - Crash reports

nonisolated extension Preferences {
    /// Whether a crashed run opens the offer to send a report.
    static var asksAfterCrash: Bool {
        get { asksAfterCrash(in: shared) }
        set { shared.set(newValue, forKey: asksAfterCrashKey) }
    }

    static let asksAfterCrashKey = "asksAfterCrash"

    static func asksAfterCrash(in defaults: UserDefaults) -> Bool {
        defaults.object(forKey: asksAfterCrashKey) as? Bool ?? true
    }

    /// Where the games muted for a finding's cause are kept. A cause whose
    /// finding only offers the report has no mute of its own: ``asksAfterCrash``
    /// speaks for all of them.
    static func quietAppsKey(for cause: RunDiagnosis.Cause) -> String? {
        switch cause {
        case .threadSpin: "quietThreadSpinApps"
        case .videoDecodedNothing: "quietVideoDecodingApps"
        case .suggestedFix: "quietSuggestedFixApps"
        case .missingLibrary: "quietMissingLibraryApps"
        case .kernelDriver: "quietKernelDriverApps"
        case .droppedShader: "quietDroppedShaderApps"
        case .unityStartup, .unrealException, .stalled, .crashed, .quitWhileStarting, .notAnswering, .unexplained:
            nil
        }
    }

    /// The causes muted for `appID`.
    static func quietCauses(forApp appID: Int, in defaults: UserDefaults = shared) -> Set<RunDiagnosis.Cause> {
        Set(RunDiagnosis.Cause.allCases.filter { cause in
            quietAppsKey(for: cause).map { (defaults.array(forKey: $0) as? [Int] ?? []).contains(appID) } ?? false
        })
    }

    /// Keeps a finding of `cause` from opening a panel for `appID` again.
    static func stopAsking(about cause: RunDiagnosis.Cause, forApp appID: Int, in defaults: UserDefaults = shared) {
        guard let key = quietAppsKey(for: cause) else { return }
        let quiet = defaults.array(forKey: key) as? [Int] ?? []
        guard !quiet.contains(appID) else { return }
        defaults.set(quiet + [appID], forKey: key)
    }

    /// A random per-install token that groups sent reports; it names nothing
    /// about the machine or account.
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
