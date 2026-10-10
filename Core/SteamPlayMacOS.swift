import Foundation

/// A game's macOS build, installed and played through the bottle's own Steam,
/// the way Steam's Linux client hands a game to a compatibility tool.
///
/// Steam's Windows client carries the whole Steam Play system. The engine
/// turns it on in `steam.exe` when `SEVO_STEAM_PLAY=1` is in its environment,
/// which ``ConfigMaterializer`` writes into `steam.exe`'s own env file. One
/// compatibility tool, registered here in `compatibilitytools.d`, declares
/// `from_oslist macos` → `to_oslist windows`: Steam offers it for every game
/// with a macOS build, and a game mapped to it (Properties › Compatibility,
/// or the install chooser, both `SpecifyCompatTool`) gets its macOS depots and
/// launches through the tool's command line, which the engine's dock shim
/// turns into the native app.
///
/// The mapping lives in Steam's own `config.vdf` (`CompatToolMapping`), so the
/// choice survives a reinstall of Sevoflurane and is where a Linux user looks
/// for it. Everything here is gated on the running engine declaring
/// ``feature`` in its `engine-info.json`.
nonisolated enum SteamPlayMacOS {
    /// The `engine-info.json` feature that says the engine switches Steam Play
    /// on and its dock shim runs a mapped game's `.app`.
    static let feature = "steam-play-macos"

    /// The line in `steam.exe`'s env file that switches Steam Play on.
    static let environmentLine = "SEVO_STEAM_PLAY=1"

    /// The env file the engine reads for `steam.exe` itself.
    static let clientEnvFile = "steam.exe.env"

    /// The tool's internal name, the value `CompatToolMapping` stores.
    static let toolName = "sevoflurane_macos"

    /// What Steam shows for the tool in Properties › Compatibility.
    static let displayName = "Native macOS version"

    /// Tool directories earlier test builds registered; removed, and their
    /// mappings moved to ``toolName``.
    static let legacyToolNames = ["sevo_macos"]

    /// The engine's launcher that Steam runs as the tool's command line.
    static let launcherName = "sevo-native.exe"

    /// The platform a mapped game installs, as `oslist` and `vecPlatforms`
    /// spell it.
    enum Platform: String, Codable, Sendable {
        case macos
        case windows
    }

    // MARK: - The tool's files

    static func toolsDirectory(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("compatibilitytools.d", isDirectory: true)
    }

    static func toolDirectory(steamRoot: URL) -> URL {
        toolsDirectory(steamRoot: steamRoot).appendingPathComponent(toolName, isDirectory: true)
    }

    /// `compatibilitytool.vdf`: the tool's name, where it lives relative to
    /// this file, and the platform pair. `to_oslist` names the host Steam runs
    /// on, which is Windows inside the bottle.
    static var compatibilityToolVDF: String {
        """
        "compatibilitytools"
        {
        \t"compat_tools"
        \t{
        \t\t\(TextKeyValues.quoted(toolName))
        \t\t{
        \t\t\t"install_path" "."
        \t\t\t"display_name" \(TextKeyValues.quoted(displayName))
        \t\t\t"from_oslist" "macos"
        \t\t\t"to_oslist" "windows"
        \t\t}
        \t}
        }
        
        """
    }

    /// `toolmanifest.vdf`: Steam prefixes a mapped game's launch with this
    /// command line, `%verb%` being `waitforexitandrun` for a Play.
    static var toolManifestVDF: String {
        """
        "manifest"
        {
        \t"version" "2"
        \t"commandline" "/\(launcherName) %verb%"
        }
        
        """
    }

    /// Writes the tool into the client's `compatibilitytools.d`, copies the
    /// engine's launcher beside it when the engine ships one, and removes the
    /// tool directories earlier builds wrote. Idempotent: a file already as
    /// wanted is left alone, so the client's own scan sees nothing change.
    /// Answers what it did, one line each, for the client log.
    @discardableResult
    static func register(steamRoot: URL, engineRoot: URL?) -> [String] {
        let manager = FileManager.default
        let directory = toolDirectory(steamRoot: steamRoot)
        var notes: [String] = []
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return ["could not create \(directory.path): \(error.localizedDescription)"]
        }
        for (name, text) in [("compatibilitytool.vdf", compatibilityToolVDF), ("toolmanifest.vdf", toolManifestVDF)] {
            let url = directory.appendingPathComponent(name)
            if (try? String(contentsOf: url, encoding: .utf8)) == text { continue }
            do {
                try text.write(to: url, atomically: true, encoding: .utf8)
                notes.append("wrote \(name)")
            } catch {
                notes.append("could not write \(name): \(error.localizedDescription)")
            }
        }
        if let engineRoot {
            let source = engineRoot.appendingPathComponent(launcherName)
            let target = directory.appendingPathComponent(launcherName)
            if manager.fileExists(atPath: source.path), !manager.contentsEqual(atPath: source.path, andPath: target.path) {
                try? manager.removeItem(at: target)
                do {
                    try manager.copyItem(at: source, to: target)
                    notes.append("copied \(launcherName) from the engine")
                } catch {
                    notes.append("could not copy \(launcherName): \(error.localizedDescription)")
                }
            }
        }
        for legacy in legacyToolNames {
            let old = toolsDirectory(steamRoot: steamRoot).appendingPathComponent(legacy, isDirectory: true)
            guard manager.fileExists(atPath: old.path) else { continue }
            if (try? manager.removeItem(at: old)) != nil { notes.append("removed the old tool \(legacy)") }
        }
        return notes
    }

    // MARK: - Mappings in config.vdf

    /// The client's `config.vdf`, which holds `CompatToolMapping`.
    static func configURL(steamRoot: URL) -> URL {
        steamRoot.appendingPathComponent("config/config.vdf")
    }

    /// Every app `config.vdf` maps to a tool, with the tool's name. App id 0
    /// is Steam Play's default for all titles, and is left out.
    static func mappings(inConfig text: String) -> [Int: String] {
        guard let root = TextKeyValues.parse(text),
              let table = mappingTable(in: root) else { return [:] }
        var result: [Int: String] = [:]
        for (key, value) in table.entries {
            guard let appID = Int(key), appID > 0, let name = value["name"]?.string, !name.isEmpty else { continue }
            result[appID] = name
        }
        return result
    }

    /// The apps mapped to ``toolName``, read from the client's `config.vdf`.
    static func mappedApps(steamRoot: URL = SteamBottle.steamRoot) -> Set<Int> {
        let text = (try? String(contentsOf: configURL(steamRoot: steamRoot), encoding: .utf8)) ?? ""
        return Set(mappings(inConfig: text).filter { $0.value == toolName }.keys)
    }

    /// `CompatToolMapping` wherever it sits under the root
    /// (`InstallConfigStore › Software › Valve › Steam`).
    private static func mappingTable(in node: TextKeyValues.Node) -> TextKeyValues.Node? {
        for (key, value) in node.entries {
            if key.caseInsensitiveCompare("CompatToolMapping") == .orderedSame { return value }
            if let found = mappingTable(in: value) { return found }
        }
        return nil
    }

    /// `config.vdf` with every mapping to a ``legacyToolNames`` tool moved to
    /// ``toolName``, the rest of the text exactly as it was; `nil` when no
    /// mapping names an old tool. Only a `"name"` value directly inside an
    /// app's block under `CompatToolMapping` is rewritten.
    static func migratingMappings(inConfig text: String) -> String? {
        let tokens = TextKeyValues.tokens(text)
        var path: [String] = []
        var pendingKey: String?
        var replacements: [Range<String.Index>] = []
        for token in tokens {
            switch token.kind {
            case let .string(value):
                guard let key = pendingKey else {
                    pendingKey = value
                    continue
                }
                pendingKey = nil
                let inMapping = path.count >= 2
                    && path[path.count - 2].caseInsensitiveCompare("CompatToolMapping") == .orderedSame
                    && Int(path[path.count - 1]) != nil
                if inMapping, key.caseInsensitiveCompare("name") == .orderedSame, legacyToolNames.contains(value) {
                    replacements.append(token.range)
                }
            case .open:
                path.append(pendingKey ?? "")
                pendingKey = nil
            case .close:
                _ = path.popLast()
                pendingKey = nil
            }
        }
        guard !replacements.isEmpty else { return nil }
        var result = text
        for range in replacements.reversed() {
            result.replaceSubrange(range, with: TextKeyValues.quoted(toolName))
        }
        return result
    }

    /// Moves mappings from an old tool to ``toolName`` in the client's
    /// `config.vdf`. Run only while the client is down: Steam rewrites the
    /// file from memory when it exits. Answers how many apps moved.
    @discardableResult
    static func migrateMappings(steamRoot: URL) -> Int {
        let url = configURL(steamRoot: steamRoot)
        guard let text = try? String(contentsOf: url, encoding: .utf8),
              let migrated = migratingMappings(inConfig: text) else { return 0 }
        let moved = mappings(inConfig: text).values.count { legacyToolNames.contains($0) }
        do {
            try migrated.write(to: url, atomically: true, encoding: .utf8)
            return moved
        } catch {
            return 0
        }
    }

    /// Everything the client needs before `steam.exe` starts on an engine
    /// with ``feature``: the tool registered and old mappings moved. The env
    /// line is ``ConfigMaterializer``'s, written by the same start.
    @discardableResult
    static func prepareClient(steamRoot: URL, engineRoot: URL?) -> [String] {
        var notes = register(steamRoot: steamRoot, engineRoot: engineRoot)
        let moved = migrateMappings(steamRoot: steamRoot)
        if moved > 0 { notes.append("moved \(moved) game(s) to \(toolName)") }
        return notes
    }
}

nonisolated extension Engine {
    /// Whether this engine switches Steam Play on in the client and runs a
    /// game mapped to ``SteamPlayMacOS/toolName`` as its macOS app.
    var supportsSteamPlayMacOS: Bool {
        features.contains(SteamPlayMacOS.feature)
    }
}
