import Digoxin
import Foundation

/// How many people use Sevoflurane, and Sevoflurane's own crashes, through
/// Digoxin at the tier the person chose (``Preferences/usageCounting``).
///
/// Independent of ``Preferences/sharesRunStats``. A check-in carries the
/// versions, chip family, memory class, language and days used in the last
/// week, and names no game or program. Game crashes go through ``RunDiagnosisPrompt``.
nonisolated enum UsageCounting {
    static let app = "sevoflurane"

    /// Production for a release build; a Debug build reports to a local
    /// Digoxin or `SEVOFLURANE_DIGOXIN_URL`.
    static let baseURL: URL = {
        #if DEBUG
            ProcessInfo.processInfo.environment["SEVOFLURANE_DIGOXIN_URL"].flatMap(URL.init(string:))
                ?? URL(string: "http://127.0.0.1:9130/api/digoxin")!
        #else
            URL(string: "https://kagerou.glass/api/digoxin")!
        #endif
    }()

    static let client = Digoxin(configuration: .init(
        app: app,
        baseURL: baseURL,
        storageDirectory: AppIdentity.supportFolder,
        log: { EventLog.enqueue(.app, "usage counting: \($0)") },
    ))

    /// At launch: applies the stored tier, sends the reports of crashes
    /// since the last look, and counts the day.
    static func start() {
        Task.detached(name: "Usage counting at launch") {
            await client.setTier(Preferences.usageCounting ?? .off)
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// On use: counts the day and sends helper crashes since the last look.
    static func noteUse() {
        Task.detached(name: "Usage counting on use") {
            await submitOwnCrashes()
            await client.recordUse()
        }
    }

    /// The person's choice, from the question card or Settings.
    static func choose(_ tier: ConsentTier) {
        let previous = Preferences.usageCounting
        Preferences.usageCounting = tier
        // Crashes from before the choice are never sent.
        if tier == .crashReports, previous != .crashReports {
            Preferences.ownCrashesCheckedAt = Date()
        }
        EventLog.enqueue(.app, "usage counting: chose \(tier.rawValue)")
        Task.detached(name: "Apply the usage counting tier") {
            await client.setTier(tier)
            if tier != .off { await client.recordUse() }
        }
    }

    /// Sends one report per crash since the last look, at the crash-reports
    /// tier. The look moves forward at every tier.
    private static func submitOwnCrashes() async {
        let now = Date()
        let since = Preferences.ownCrashesCheckedAt
        Preferences.ownCrashesCheckedAt = now
        guard Preferences.usageCounting == .crashReports, let since else { return }
        let found = OwnCrashReports.processNames.flatMap {
            DiagnosticReports.reports(forProcess: $0, after: since)
        }
        for report in OwnCrashReports.ours(found, identity: .running) {
            await client.submitCrashReport(files: [report])
        }
    }
}

/// Which of the crash reports macOS wrote belong to this copy of Sevoflurane.
///
/// Debug and installed builds share process names and macOS masks
/// `procPath` (`/Users/USER/*/…`), so the header line's bundle identifier
/// and image UUID tell them apart.
nonisolated enum OwnCrashReports {
    /// The app and its background helper.
    static let processNames = ["Sevoflurane", "SevofluraneDaemon"]

    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// What this copy's crashes carry in their header line.
    struct Identity: Equatable {
        /// The app's bundle identifier, which an app crash names.
        var bundleID: String?
        /// The Mach-O UUIDs of the app and its helper, uppercase; a helper
        /// crash has no bundle identifier.
        var imageUUIDs: Set<String>

        static var running: Identity {
            let helper = Bundle.main.bundleURL.appending(path: "Contents/Library/LaunchAgents/SevofluraneDaemon")
            return Identity(
                bundleID: Bundle.main.bundleIdentifier,
                imageUUIDs: Set([MachOIdentity.ofThisProcess, MachOIdentity.ofFile(helper)].compactMap(\.self)),
            )
        }
    }

    /// The crashes among `reports` that are this copy's.
    static func ours(_ reports: [URL], identity: Identity) -> [URL] {
        reports.filter { url in
            guard let data = try? Data(contentsOf: url) else { return false }
            return isCrash(data, of: identity)
        }
    }

    /// Whether an `.ips` file (a JSON header line, then the JSON body) is a
    /// crash of the app or the helper `identity` describes.
    static func isCrash(_ ips: Data, of identity: Identity) -> Bool {
        let line = ips.prefix { $0 != UInt8(ascii: "\n") }
        guard let header = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              header["bug_type"] as? String == crashBugType
        else { return false }
        if let bundleID = identity.bundleID, header["bundleID"] as? String == bundleID { return true }
        guard let uuid = header["slice_uuid"] as? String else { return false }
        return identity.imageUUIDs.contains(uuid.uppercased())
    }
}

// MARK: - Preferences

nonisolated extension Preferences {
    /// The Digoxin tier the person chose; `nil` until asked.
    static var usageCounting: ConsentTier? {
        get { shared.string(forKey: usageCountingKey).flatMap(ConsentTier.init(rawValue:)) }
        set { shared.set(newValue?.rawValue, forKey: usageCountingKey) }
    }

    static let usageCountingKey = "usageCounting"

    /// When own crash reports were last looked for; later ones are unsent.
    static var ownCrashesCheckedAt: Date? {
        get { app.object(forKey: "ownCrashesCheckedAt") as? Date }
        set { app.set(newValue, forKey: "ownCrashesCheckedAt") }
    }
}
