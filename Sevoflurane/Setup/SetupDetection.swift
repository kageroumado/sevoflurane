import Foundation

/// What SevoKit can learn about this machine without touching anything —
/// the facts the first-run assistant and `sevo doctor` both read.
nonisolated struct SetupDetection: Sendable, Equatable {
    struct CrossOver: Sendable, Equatable {
        let version: String
        let licensed: Bool
        let expires: String?
        /// An installed CrossOver whose trial ran out cannot launch bottles;
        /// the wizard must treat it as unavailable, not silently pick it.
        let trialExpired: Bool
    }

    struct Bottle: Sendable, Equatable {
        let name: String
        let url: URL
        let hasSteam: Bool
    }

    let rosetta: Bool
    let crossover: CrossOver?
    let bottles: [Bottle]
    let managedEngineVersions: [String]
    /// CodeWeavers' preview app, when installed alongside stable. It shares
    /// the license, so usability follows the same rule.
    var crossoverPreview: CrossOver? = nil

    /// The bottle setup would adopt, when exactly one candidate exists.
    var steamBottles: [Bottle] {
        bottles.filter(\.hasSteam)
    }

    var usableCrossOver: CrossOver? {
        guard let crossover, crossover.licensed || !crossover.trialExpired else {
            return nil
        }
        return crossover
    }

    var usableCrossOverPreview: CrossOver? {
        guard let crossoverPreview,
              crossoverPreview.licensed || !crossoverPreview.trialExpired else {
            return nil
        }
        return crossoverPreview
    }

    var hasEngine: Bool {
        usableCrossOver != nil || usableCrossOverPreview != nil
            || !managedEngineVersions.isEmpty
    }
}

nonisolated enum SetupProbe {
    static let crossoverApp = URL(fileURLWithPath: "/Applications/CrossOver.app")
    static let crossoverPreviewApp = URL(fileURLWithPath: "/Applications/CrossOver Preview.app")
    static let crossoverBottles = SteamBottle.bottlesRoot
    static let managedEngines = Engine.managedRoot
    private static let license = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.license")
    private static let preferences = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.plist")
    private static let trialDays = 14.0

    static func detect() async -> SetupDetection {
        await SetupDetection(
            rosetta: rosettaWorks(),
            crossover: crossoverInfo(),
            bottles: bottles(),
            managedEngineVersions: managedEngineVersions(),
            crossoverPreview: crossoverInfo(at: crossoverPreviewApp),
        )
    }

    /// The whole stack is x86_64; without Rosetta nothing below runs.
    static func rosettaWorks() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/arch")
        process.arguments = ["-x86_64", "/usr/bin/true"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return false
        }
        return await withCheckedContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus == 0) }
        }
    }

    /// The license is a plain INI (`[crossmac] … expires=YYYY/MM/DD` +
    /// `[license] id=…`); licensed = an id is present and any expiry is in
    /// the future. Trial state comes from FirstRunDate in the preferences.
    /// The Preview app carries its own version but shares the license and
    /// first-run record, so both apps read the same two files.
    static func crossoverInfo(
        at app: URL = crossoverApp,
    ) -> SetupDetection.CrossOver? {
        let infoPlist = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
              as? [String: Any] else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"

        let licenseText = (try? String(contentsOf: license, encoding: .utf8)) ?? ""
        let (licensed, expires) = parseLicense(licenseText)

        var trialExpired = false
        if !licensed,
           let prefs = try? PropertyListSerialization.propertyList(
               from: Data(contentsOf: preferences), format: nil,
           ) as? [String: Any],
           let firstRun = prefs["FirstRunDate"] as? Date {
            trialExpired = Date.now.timeIntervalSince(firstRun) > trialDays * 86_400
        }
        return SetupDetection.CrossOver(
            version: version,
            licensed: licensed,
            expires: expires,
            trialExpired: trialExpired,
        )
    }

    /// Parses the license INI: licensed = a `[license]` id is present and any
    /// `expires=YYYY/MM/DD` is in the future.
    static func parseLicense(_ text: String, now: Date = .now) -> (licensed: Bool, expires: String?) {
        var licensed = text.contains("[license]") && text.contains("id=")
        var expires: String?
        for line in text.split(whereSeparator: \.isNewline) where line.hasPrefix("expires=") {
            let date = String(line.dropFirst("expires=".count))
                .trimmingCharacters(in: .whitespaces)
            expires = date
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy/MM/dd"
            formatter.locale = Locale(identifier: "en_US_POSIX")
            if let parsed = formatter.date(from: date) {
                licensed = licensed && parsed > now
            }
        }
        return (licensed, expires)
    }

    /// CrossOver's bottles (a `cxbottle.conf` marks a real one) plus the
    /// managed engine's prefixes (a `drive_c` marks those). One list — the
    /// wizard and doctor don't care which engine owns a bottle, only the URL.
    static func bottles() -> [SetupDetection.Bottle] {
        // system.reg is written at the end of `wineboot -u`, so a prefix
        // whose boot died halfway reads as "no bottle" and gets rebuilt —
        // `drive_c` appears first and let a corpse pass detection.
        bottles(under: crossoverBottles, marker: "cxbottle.conf")
            + bottles(under: Engine.previewBottlesRoot, marker: "cxbottle.conf")
            + bottles(under: Engine.managedBottlesRoot, marker: "system.reg")
    }

    /// The bottles the given engine can actually drive — its own root only.
    static func bottles(for engine: Engine) -> [SetupDetection.Bottle] {
        bottles(
            under: engine.bottlesRoot,
            marker: engine.isCrossOver ? "cxbottle.conf" : "system.reg",
        )
    }

    private static func bottles(under root: URL, marker: String) -> [SetupDetection.Bottle] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: root.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            let url = root.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.appendingPathComponent(marker).path) else {
                return nil
            }
            let steamDLL = SteamBottle.steamRoot(inBottle: url)
                .appendingPathComponent("steamclient64.dll")
            return SetupDetection.Bottle(
                name: name,
                url: url,
                hasSteam: manager.fileExists(atPath: steamDLL.path),
            )
        }
    }

    static func managedEngineVersions() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: managedEngines.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
