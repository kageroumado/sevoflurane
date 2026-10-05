import Digoxin
import Foundation

/// How many people use Sevoflurane, and Sevoflurane's own crashes, through
/// Digoxin at the tier the person chose (``Preferences/usageCounting``).
///
/// Independent of the community database (``Preferences/sharesRunStats``):
/// a check-in carries the versions, the chip family, the memory class, the
/// language and the count of days used in the last week, and names no game
/// or program. The server keeps no properties for this app, so none are
/// sent. A game's crash stays on ``CrashPrompt``'s path, sent only when the
/// player chooses.
nonisolated enum UsageCounting {
    static let app = "sevoflurane"

    /// Production for a release build. A Debug build is a second
    /// installation (``AppIdentity``) and reports to a Digoxin on this Mac,
    /// or to the one `SEVOFLURANE_DIGOXIN_URL` names.
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

    /// The app came forward or its popover opened: counts the day, and
    /// sends a helper crash that happened while the app stayed up.
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
        // Crashes before the choice are not the choice's to send.
        if tier == .crashReports, previous != .crashReports {
            Preferences.ownCrashesCheckedAt = Date()
        }
        EventLog.enqueue(.app, "usage counting: chose \(tier.rawValue)")
        Task.detached(name: "Apply the usage counting tier") {
            await client.setTier(tier)
            if tier != .off { await client.recordUse() }
        }
    }

    /// One report per crash of the app or its helper since the last look,
    /// at the crash-reports tier; the look moves forward at every tier, so
    /// turning reports on later sends nothing from before.
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
/// A Debug build and the installed app run under the same process names, and
/// macOS writes `procPath` with the home folder and other volumes masked
/// (`/Users/USER/*/…`), so the path cannot tell them apart. The header line
/// can: the app's crash names its bundle identifier, which differs between
/// the two, and every crash names the UUID of the image that crashed.
nonisolated enum OwnCrashReports {
    /// The app and the background helper inside it. Wine and game
    /// processes are the games', never these.
    static let processNames = ["Sevoflurane", "SevofluraneDaemon"]

    /// `bug_type` of a crash. A hang or a spin is written under other types.
    static let crashBugType = "309"

    /// What this copy's crashes carry in their header line.
    struct Identity: Equatable {
        /// The app's bundle identifier: a crash of the app names it, whichever
        /// build of this installation crashed.
        var bundleID: String?
        /// The Mach-O UUIDs of the app and its helper, uppercase: the helper is
        /// a tool, and its crashes are this build's when the UUID matches.
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
    /// The Digoxin tier the person chose; `nil` until they have been asked,
    /// which is what makes the question appear once.
    static var usageCounting: ConsentTier? {
        get { shared.string(forKey: usageCountingKey).flatMap(ConsentTier.init(rawValue:)) }
        set { shared.set(newValue?.rawValue, forKey: usageCountingKey) }
    }

    static let usageCountingKey = "usageCounting"

    /// When the crash reports of the app and its helper were last looked
    /// for: reports written after it are the ones not yet sent.
    static var ownCrashesCheckedAt: Date? {
        get { app.object(forKey: "ownCrashesCheckedAt") as? Date }
        set { app.set(newValue, forKey: "ownCrashesCheckedAt") }
    }
}
