import Foundation

/// The single description of the bottled Steam installation: where the
/// bottle lives on disk, the client's paths inside it, and the translation
/// from the Windows paths Steam hands out to the macOS paths that exist.
nonisolated enum SteamBottle {
    /// The bottle's name — also the last component of ``root``.
    static let name = "Steam"

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

    /// The client's Chromium profile cache. A corrupt one crash-loops the
    /// webhelper at startup; trashing it is the first hygiene rung.
    /// CrossOver bottles run as the `crossover` Windows user; plain Wine
    /// prefixes as the macOS username.
    static var htmlcache: URL {
        let user = Engine.active == .crossover ? "crossover" : NSUserName()
        return root.appendingPathComponent(
            "drive_c/users/\(user)/AppData/Local/Steam/htmlcache")
    }

    /// `steam.cfg` next to steam.exe — the update-pinning emergency brake.
    static var steamCfg: URL {
        steamRoot.appendingPathComponent("steam.cfg")
    }

    /// The client executable, as the Windows side names it.
    static let exeWindowsPath = #"C:\Program Files (x86)\Steam\Steam.exe"#

    /// CrossOver's CLI tools (wine, wineserver, cxbottle).
    static let crossoverBin = "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin"

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
