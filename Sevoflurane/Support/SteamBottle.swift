import Foundation

/// The single description of the bottled Steam installation: where the
/// bottle lives on disk, the client's paths inside it, and the translation
/// from the Windows paths Steam hands out to the macOS paths that exist.
nonisolated enum SteamBottle {
    /// The bottle's name — also the last component of ``root``.
    ///
    /// A machine can carry several Steam bottles (CrossOver's own "Steam",
    /// one from a previous experiment, one per engine); the wizard asks which
    /// is ours when it finds more than one, and every path below follows the
    /// answer. Both faces read it from the shared suite, so `sevo` and the app
    /// never drive different bottles.
    static var name: String {
        Preferences.shared.string(forKey: nameKey) ?? defaultName
    }

    /// Names the bottle this installation drives. Takes effect for paths
    /// computed after it returns, so the client is restarted around it.
    static func choose(_ name: String) {
        Preferences.shared.set(name, forKey: nameKey)
    }

    /// The name CrossOver's own Steam bottle carries, and what the wizard
    /// creates when it makes one.
    static let defaultName = "Steam"

    private static let nameKey = "bottleName"

    /// CrossOver's bottles directory, holding every bottle by name.
    static let bottlesRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/CrossOver/Bottles")

    /// The Steam bottle itself, wherever the active engine keeps bottles.
    static var root: URL {
        Engine.active.bottlesRoot.appendingPathComponent(name)
    }

    /// The client's install prefix inside a given bottle.
    static func steamRoot(inBottle bottle: URL) -> URL {
        bottle.appendingPathComponent("drive_c/Program Files (x86)/Steam")
    }

    /// The client's install prefix inside the Steam bottle.
    static var steamRoot: URL {
        steamRoot(inBottle: root)
    }

    /// Steam's UI bundle, served by the bridge with the shim injected.
    static var steamui: URL {
        steamRoot.appendingPathComponent("steamui")
    }

    /// Capsule art cache, served by the bridge's art endpoint.
    static var libraryCache: URL {
        steamRoot.appendingPathComponent("appcache/librarycache")
    }

    /// Crash and assert dumps the client drops when steamwebhelper dies;
    /// their arrival rate is the crash-loop signature.
    static var dumps: URL {
        steamRoot.appendingPathComponent("dumps")
    }

    /// The Windows user the bottle runs as, and so the name of the profile
    /// directory under `drive_c/users`. CrossOver bottles run as `crossover`;
    /// plain Wine prefixes as the macOS username.
    static var windowsUser: String {
        Engine.active.isCrossOver ? "crossover" : NSUserName()
    }

    /// The client's Chromium profile cache. A corrupt one crash-loops the
    /// webhelper at startup; trashing it is the first hygiene rung.
    static var htmlcache: URL {
        root.appendingPathComponent(
            "drive_c/users/\(windowsUser)/AppData/Local/Steam/htmlcache",
        )
    }

    /// `steam.cfg` next to steam.exe — the update-pinning emergency brake.
    static var steamCfg: URL {
        steamRoot.appendingPathComponent("steam.cfg")
    }

    /// Steam's downloaded and precompiled GPU shader cache, under `steamapps`
    /// beside `common`. Steam refetches and recompiles it on demand, so
    /// trashing it forces a rebuild and loses nothing: it holds no saves and
    /// no game files. A shader glitch — a black screen, a stuck load — that a
    /// plain restart does not clear is what clearing it is for. The path stays
    /// inside `steamapps/shadercache` so a reset built on it can never reach
    /// `common` (games) or `userdata` (saves).
    static var shaderCache: URL {
        steamRoot.appendingPathComponent("steamapps/shadercache")
    }

    /// The client executable, as the Windows side names it.
    static let exeWindowsPath = #"C:\Program Files (x86)\Steam\Steam.exe"#

    /// CrossOver's CLI tools (wine, wineserver, cxbottle).
    static let crossoverBin = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"

    /// Where the client keeps one app's screenshots, or `nil` when the tree
    /// does not exist yet.
    ///
    /// Steam writes them under the signed-in account —
    /// `userdata/<account>/760/remote/<appid>/screenshots` — and creates
    /// `760` only once a screenshot has been taken, so what opens is the
    /// deepest directory that is actually there. More than one account can
    /// have signed in on this machine; the one that has the app's folder
    /// wins over one that only has the tree.
    static func screenshots(forApp appID: String) -> URL? {
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

    /// The Windows path for a macOS file, as the bottle sees it: inside the
    /// bottle everything is on `C:`, and the rest of the Mac is reachable
    /// through the `Z:` mapping of the filesystem root that every prefix has.
    static func windowsPath(for url: URL) -> String {
        let path = url.standardizedFileURL.path
        let driveC = root.appendingPathComponent("drive_c").standardizedFileURL.path
        if path == driveC || path.hasPrefix(driveC + "/") {
            let rest = String(path.dropFirst(driveC.count))
            return "C:" + rest.replacingOccurrences(of: "/", with: #"\"#)
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: #"\"#)
    }

    /// Translates the bottle's Windows paths into macOS paths.
    ///
    /// Steam hands out paths like `C:\Program Files (x86)\Steam\steamapps\common\…`;
    /// what actually exists is the bottle's `drive_c`. The drive letters are
    /// resolved through the bottle's own `dosdevices` symlinks (`c:` → `../drive_c`,
    /// `z:` → `/`), so any mapping CrossOver knows about is honored without a
    /// hardcoded table.
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
