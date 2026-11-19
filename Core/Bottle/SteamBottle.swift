import Foundation

/// The bottled Steam installation: where the bottle lives, the client's paths
/// inside it, and the translation between Windows and macOS paths.
nonisolated enum SteamBottle {
    /// The bottle's name, the last component of ``root``. The wizard asks
    /// which bottle is ours when it finds several; `sevo` and the app read it
    /// from the shared suite so they never drive different bottles.
    static var name: String {
        Preferences.shared.string(forKey: nameKey) ?? defaultName
    }

    /// Names the bottle this installation drives. Paths computed earlier keep
    /// the old bottle, so the client is restarted around it.
    static func choose(_ name: String) {
        Preferences.shared.set(name, forKey: nameKey)
    }

    /// CrossOver's own Steam bottle name, and what the wizard creates.
    static let defaultName = "Steam"

    private static let nameKey = "bottleName"

    static let bottlesRoot = UserHome.url
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")

    static var root: URL {
        Engine.active.bottlesRoot.appendingPathComponent(name)
    }

    /// Where companion prefixes (``SteamParent``) live, outside every
    /// bottles directory.
    static let companionsRoot = AppIdentity.supportFolder
        .appendingPathComponent("Companions")

    /// The Steam bottle's companion prefix, where the programs that need a
    /// `steam.exe` parent run and write their frame counters.
    static var companion: URL {
        companionsRoot.appendingPathComponent(name)
    }

    static func steamRoot(inBottle bottle: URL) -> URL {
        bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    }

    static var steamRoot: URL {
        steamRoot(inBottle: root)
    }

    /// Where the client logs when its session ends.
    static var connectionLog: URL {
        steamRoot.appendingPathComponent("logs/connection_log.txt")
    }

    /// Steam's UI bundle, served by the bridge with the shim injected.
    static var steamui: URL {
        steamRoot.appendingPathComponent("steamui")
    }

    /// Capsule art cache, served by the bridge's art endpoint.
    static var libraryCache: URL {
        steamRoot.appendingPathComponent("appcache/librarycache")
    }

    /// The signed-in account's custom library art,
    /// `userdata/<account id>/config/grid`, where `SetCustomArtworkForApp`
    /// writes and `/customimages/` reads. `nil` before anyone has signed in.
    static var customArtwork: URL? {
        guard let text = try? String(
            contentsOf: steamRoot.appendingPathComponent("config/loginusers.vdf"), encoding: .utf8,
        ), let account = signedInAccountID(loginUsers: text) else { return nil }
        return steamRoot.appendingPathComponent("userdata/\(account)/config/grid")
    }

    /// The 32-bit account id of the entry marked `MostRecent` in
    /// `loginusers.vdf`, else the newest `timestamp`. Entries are keyed by
    /// 64-bit SteamID, whose low word is the account id.
    static func signedInAccountID(loginUsers text: String) -> UInt32? {
        let users = TextKeyValues.parse(text)?["users"]?.entries ?? []
        let marked = users.first { $0.value["MostRecent"]?.string == "1" }
        let chosen = marked ?? users.max {
            Int($0.value["timestamp"]?.string ?? "") ?? 0 < Int($1.value["timestamp"]?.string ?? "") ?? 0
        }
        guard let chosen, let steamID = UInt64(chosen.key) else { return nil }
        return UInt32(truncatingIfNeeded: steamID)
    }

    /// Dumps the client drops when steamwebhelper dies; their arrival rate is
    /// the crash-loop signature.
    static var dumps: URL {
        steamRoot.appendingPathComponent("dumps")
    }

    /// The profile directory name under `drive_c/users`: `crossover` in
    /// CrossOver bottles, the macOS username in plain Wine prefixes.
    static var windowsUser: String {
        Engine.active.isCrossOver ? "crossover" : NSUserName()
    }

    /// The client's Chromium profile cache. A corrupt one crash-loops the
    /// webhelper at startup.
    static var htmlcache: URL {
        root.appendingPathComponent(
            "drive_c/users/\(windowsUser)/AppData/Local/Steam/htmlcache",
        )
    }

    /// `steam.cfg` next to steam.exe — the update-pinning emergency brake.
    static var steamCfg: URL {
        steamRoot.appendingPathComponent("steam.cfg")
    }

    /// Steam's GPU shader cache, which Steam rebuilds on demand, so trashing
    /// it clears a shader glitch and loses nothing. Keep the path inside
    /// `steamapps/shadercache` so a reset can never reach `common` (games) or
    /// `userdata` (saves).
    static var shaderCache: URL {
        steamRoot.appendingPathComponent("steamapps/shadercache")
    }

    static let exeWindowsPath = #"C:\Program Files (x86)\Steam\Steam.exe"#

    static var exe: URL {
        steamRoot.appendingPathComponent("Steam.exe")
    }

    /// CrossOver's CLI tools (wine, wineserver, cxbottle).
    static let crossoverBin = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"

    /// The deepest existing directory of
    /// `userdata/<account>/760/remote/<appid>/screenshots`, preferring an
    /// account that has the app's folder; `nil` before any screenshot
    /// (Steam creates `760` with the first).
    static func screenshots(forApp appID: String) -> URL? {
        // A game id is decimal digits; anything else would walk the path.
        guard !appID.isEmpty, appID.unicodeScalars.allSatisfy({ ("0" ... "9").contains($0) }) else { return nil }
        let accounts = (try? FileManager.default.contentsOfDirectory(
            at: steamRoot.appendingPathComponent("userdata"),
            includingPropertiesForKeys: nil,
        )) ?? []
        for suffix in ["760/remote/\(appID)/screenshots", "760/remote/\(appID)", "760/remote"] {
            for account in accounts {
                let candidate = account.appendingPathComponent(suffix)
                if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            }
        }
        return nil
    }

    /// The Windows path for a macOS file: `C:` inside the bottle's
    /// `drive_c`, `Z:` (the filesystem root) everywhere else.
    static func windowsPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let driveC = root.appendingPathComponent("drive_c").standardizedFileURL.path
        if path == driveC || path.hasPrefix(driveC + "/") {
            let rest = String(path.dropFirst(driveC.count))
            return "C:" + rest.replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }

    /// Translates a Windows path Steam hands out into an existing macOS path,
    /// resolving the drive letter through the bottle's `dosdevices` symlinks
    /// (`c:` → `../drive_c`, `z:` → `/`).
    static func macURL(fromWindowsPath path: String) -> URL? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count >= 2,
              normalized[normalized.index(after: normalized.startIndex)] == ":" else {
            // Already a POSIX path (Steam under Proton reports those too).
            return normalized.hasPrefix("/") ? URL(fileURLWithPath: normalized) : nil
        }
        let letter = String(normalized.prefix(1)).lowercased()
        let device = root.appendingPathComponent("dosdevices/\(letter):")
        let deviceRoot = device.resolvingSymlinksInPath()
        let rest = String(normalized.dropFirst(2)).trimmingCharacters(in: ["/"])
        let target = rest.isEmpty ? deviceRoot : deviceRoot.appendingPathComponent(rest)
        guard FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }
}
