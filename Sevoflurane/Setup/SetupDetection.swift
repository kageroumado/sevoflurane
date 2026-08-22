import Foundation

/// What SevoKit can learn about this machine without touching anything —
/// the facts the first-run assistant and `sevo doctor` both read
/// (`Docs/onboarding-spec.md` S0–S3).
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

    /// The bottle setup would adopt, when exactly one candidate exists.
    var steamBottles: [Bottle] { bottles.filter(\.hasSteam) }

    var usableCrossOver: CrossOver? {
        guard let crossover, crossover.licensed || !crossover.trialExpired else {
            return nil
        }
        return crossover
    }

    var hasEngine: Bool { usableCrossOver != nil || !managedEngineVersions.isEmpty }
}

nonisolated enum SetupProbe {
    static let crossoverApp = URL(fileURLWithPath: "/Applications/CrossOver.app")
    static let crossoverBottles = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")
    static let managedEngines = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Engines")
    private static let license = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.license")
    private static let preferences = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Preferences/com.codeweavers.CrossOver.plist")
    private static let trialDays = 14.0

    static func detect() async -> SetupDetection {
        SetupDetection(rosetta: await rosettaWorks(),
                       crossover: crossoverInfo(),
                       bottles: bottles(),
                       managedEngineVersions: managedEngineVersions())
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
    static func crossoverInfo() -> SetupDetection.CrossOver? {
        let infoPlist = crossoverApp.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoPlist),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil)
                as? [String: Any] else { return nil }
        let version = info["CFBundleShortVersionString"] as? String ?? "?"

        var licensed = false
        var expires: String?
        if let text = try? String(contentsOf: license, encoding: .utf8) {
            licensed = text.contains("[license]") && text.contains("id=")
            for line in text.split(whereSeparator: \.isNewline)
            where line.hasPrefix("expires=") {
                let date = String(line.dropFirst("expires=".count))
                    .trimmingCharacters(in: .whitespaces)
                expires = date
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy/MM/dd"
                formatter.locale = Locale(identifier: "en_US_POSIX")
                if let parsed = formatter.date(from: date) {
                    licensed = licensed && parsed > .now
                }
            }
        }

        var trialExpired = false
        if !licensed,
           let prefs = try? PropertyListSerialization.propertyList(
            from: Data(contentsOf: preferences), format: nil) as? [String: Any],
           let firstRun = prefs["FirstRunDate"] as? Date {
            trialExpired = Date.now.timeIntervalSince(firstRun) > trialDays * 86_400
        }
        return SetupDetection.CrossOver(version: version, licensed: licensed,
                                        expires: expires, trialExpired: trialExpired)
    }

    static func bottles() -> [SetupDetection.Bottle] {
        let manager = FileManager.default
        guard let names = try? manager.contentsOfDirectory(atPath: crossoverBottles.path) else {
            return []
        }
        return names.sorted().compactMap { name in
            let url = crossoverBottles.appendingPathComponent(name)
            guard manager.fileExists(atPath: url.appendingPathComponent("cxbottle.conf").path) else {
                return nil
            }
            let steamDLL = url.appendingPathComponent(
                "drive_c/Program Files (x86)/Steam/steamclient64.dll")
            return SetupDetection.Bottle(name: name, url: url,
                                         hasSteam: manager.fileExists(atPath: steamDLL.path))
        }
    }

    static func managedEngineVersions() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: managedEngines.path)) ?? [])
            .filter { !$0.hasPrefix(".") }
            .sorted()
    }
}
