import Foundation

/// What can be learned about this machine without touching anything: the
/// facts the first-run assistant and `sevo doctor` both read.
nonisolated struct SetupDetection: Sendable, Equatable {
    struct CrossOver: Sendable, Equatable {
        let version: String
        let licensed: Bool
        let expires: String?
        /// An installed CrossOver whose trial ran out cannot launch bottles,
        /// so the wizard treats it as unavailable.
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
    /// CodeWeavers' preview app, which shares the stable app's license.
    var crossoverPreview: CrossOver?

    /// Every bottle with a Steam install.
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
    private static let license = UserHome.url
        .appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.license")
    private static let preferences = UserHome.url
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

    /// Whether x86_64 code runs; always true on an Intel Mac.
    static func rosettaWorks() async -> Bool {
        guard MacHardware.isAppleSilicon else { return true }
        let result = await Subprocess.run(
            "/usr/bin/arch", ["-x86_64", "/usr/bin/true"], capture: .none, timeout: .seconds(10),
        )
        return result.status == 0
    }

    /// Trial state comes from FirstRunDate; the Preview app shares the
    /// license and first-run record with the stable one.
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

    /// Parses the license, a plain INI (`[crossmac] … expires=YYYY/MM/DD`,
    /// `[license] id=…`): licensed = a `[license]` id is present and any
    /// expiry is in the future.
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

    /// CrossOver's bottles (marked by `cxbottle.conf`) and the managed
    /// engine's prefixes (marked by `system.reg`), in one list.
    static func bottles() -> [SetupDetection.Bottle] {
        // wineserver saves system.reg within seconds even of a killed boot;
        // `SetupEnvironment.bottleIsComplete` judges whether it finished.
        bottles(under: crossoverBottles, marker: "cxbottle.conf")
            + bottles(under: Engine.previewBottlesRoot, marker: "cxbottle.conf")
            + bottles(under: Engine.managedBottlesRoot, marker: "system.reg")
    }

    /// The bottles under the engine's own root.
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
        let current = SteamBottle.name
        return names.sorted().compactMap { name in
            // The configured bottle counts whatever its name.
            guard name == current || !isSetAside(name) else { return nil }
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

    /// Whether a folder's name marks a set-aside bottle: hidden, or a
    /// retiring suffix (`Steam.discard`, `Steam.stub-1308`, `Steam.old`).
    /// Only the name can tell, since its contents may be a whole prefix.
    static func isSetAside(_ name: String) -> Bool {
        if name.hasPrefix(".") { return true }
        let suffix = (name as NSString).pathExtension.lowercased()
        guard let word = suffix.split(separator: "-", maxSplits: 1).first else { return false }
        return setAsideSuffixes.contains(String(word))
    }

    /// The words a set-aside suffix starts with; `stub-1308` counts as `stub`.
    private static let setAsideSuffixes: Set<String> = [
        "discard", "discarded", "stub", "quarantine", "quarantined", "old", "bak", "backup",
        "orig", "tmp", "partial", "broken", "trash",
    ]

    /// Installed engines whose wineserver this Mac runs, oldest first by
    /// ``Engine/isOlderVersion(_:than:)`` (`dormison-r2` before `dormison-r10`,
    /// `dormison-b11` between `dormison-r10` and `dormison-r11`).
    static func managedEngineVersions() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: managedEngines.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .filter { Engine.serverRuns(inEngineAt: managedEngines.appendingPathComponent($0)) }
            .sorted(by: Engine.isOlderVersion)
    }
}
