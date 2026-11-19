import Foundation

/// Adopted programs as non-Steam games in Steam's own library, so Big Picture,
/// Steam Input and the overlay reach them as they reach a store game.
///
/// The client owns `shortcuts.vdf` and rewrites it from memory, so the list is
/// changed only through the client's own calls (`SteamClient.Apps.AddShortcut`
/// and its siblings) on the bridge's connection. Each shortcut's app id is
/// kept in the program's record; Steam's launch and lifetime events name a
/// shortcut by that id, and the app maps it back to the program's own id
/// before anything else reads it, so a run Steam starts gets the run record,
/// status line and Discord activity a Quick Launch start gets. The env file
/// and the Dock tile need nothing: the engine finds both by the executable's
/// name.
nonisolated enum SteamShortcuts {
    // MARK: - Ids

    /// `k_EGameIDTypeShortcut`, in bits 24 to 31 of a 64-bit game id.
    private static let shortcutType: UInt64 = 2

    /// The bit Steam sets on every shortcut's 32-bit app id.
    private static let shortcutBit: UInt64 = 0x8000_0000

    /// The shortcut app id a Steam event names, if it names one: a game
    /// action's 64-bit game id (app id in the high word, type 2 in bits 24 to
    /// 31), or a lifetime notification's 32-bit app id (high bit set).
    static func shortcutID(in steamID: String) -> Int? {
        guard let value = UInt64(steamID) else { return nil }
        if value <= UInt64(UInt32.max) {
            return value & shortcutBit != 0 ? Int(value) : nil
        }
        guard (value >> 24) & 0xFF == shortcutType, (value >> 32) & shortcutBit != 0 else { return nil }
        return Int(value >> 32)
    }

    /// The 64-bit game id Steam's calls (`TerminateApp` among them) take for
    /// a shortcut.
    static func gameID(shortcutID: Int) -> String {
        String(UInt64(UInt32(truncatingIfNeeded: shortcutID)) << 32 | shortcutType << 24)
    }

    /// The adopted program's id for a shortcut in `aliases`, else the id
    /// itself.
    static func appID(fromSteam steamID: String, aliases: [Int: Int]) -> Int? {
        if let shortcut = shortcutID(in: steamID), let program = aliases[shortcut] {
            return program
        }
        return Int(steamID)
    }

    /// Shortcut app id → adopted program id.
    static func aliases(_ entries: [AdoptedPrograms.Entry]) -> [Int: Int] {
        var aliases: [Int: Int] = [:]
        for entry in entries {
            guard let shortcut = entry.program.steamShortcutID else { continue }
            aliases[shortcut] = entry.id
        }
        return aliases
    }

    // MARK: - Matching

    /// An executable path for comparison, without Steam's quotes and case.
    static func exeKey(_ windowsPath: String) -> String {
        var path = windowsPath.trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return path.replacingOccurrences(of: "/", with: #"\"#).lowercased()
    }

    /// ``exeKey(_:)`` without Steam's closing backslash.
    static func folderKey(_ windowsPath: String) -> String {
        var key = exeKey(windowsPath)
        while key.hasSuffix(#"\"#), key.count > 3 {
            key.removeLast()
        }
        return key
    }

    /// A program's arguments as one launch-option line, quoted for
    /// `CommandLineToArgvW`.
    static func launchOptions(_ arguments: [String]) -> String {
        arguments.map(quoted).joined(separator: " ")
    }

    private static func quoted(_ token: String) -> String {
        guard token.isEmpty || token.contains(where: { $0 == " " || $0 == "\t" || $0 == "\"" }) else {
            return token
        }
        var result = "\""
        var backslashes = 0
        for character in token {
            switch character {
            case "\\":
                backslashes += 1
            case "\"":
                result += String(repeating: "\\", count: backslashes * 2 + 1) + "\""
                backslashes = 0
            default:
                result += String(repeating: "\\", count: backslashes) + String(character)
                backslashes = 0
            }
        }
        return result + String(repeating: "\\", count: backslashes * 2) + "\""
    }

    // MARK: - The target

    /// What a shortcut starts, as plain Windows paths; the scripts quote them
    /// as Steam does.
    struct Target: Equatable, Sendable {
        let exe: String
        let startDir: String
        let launchOptions: String

        var quotedExe: String {
            "\"\(exe)\""
        }

        /// In quotes and ending in a backslash, as Steam keeps it.
        var quotedStartDir: String {
            var folder = startDir
            while folder.hasSuffix(#"\"#) {
                folder.removeLast()
            }
            return "\"\(folder)\\\""
        }
    }

    /// A program's target, starting in the executable's own folder.
    static func target(_ program: AdoptedProgram) -> Target {
        let folder = program.url.deletingLastPathComponent()
        return Target(
            exe: SteamBottle.windowsPath(for: program.url),
            startDir: SteamBottle.windowsPath(for: folder),
            launchOptions: launchOptions(program.arguments),
        )
    }

    static func starts(_ listed: Listed, _ target: Target) -> Bool {
        exeKey(listed.exe) == exeKey(target.exe)
            && folderKey(listed.startDir) == folderKey(target.startDir)
            && listed.launchOptions.trimmingCharacters(in: .whitespaces)
            == target.launchOptions.trimmingCharacters(in: .whitespaces)
    }

    // MARK: - The plan

    /// One shortcut in Steam's list.
    struct Listed: Decodable, Equatable, Sendable {
        var appid: Int
        var exe: String
        var startDir = ""
        var launchOptions = ""
    }

    /// One adopted program as a pass weighs it.
    struct Program: Equatable, Sendable {
        let id: Int
        let target: Target
        /// The user wants it in Steam's library and it can run under the
        /// client.
        let wanted: Bool
        let shortcutID: Int?
    }

    /// What one pass changes, in Steam's list and in the records.
    struct Plan: Equatable, Sendable {
        /// Program id → its shortcut: the record's own, or a listed one that
        /// starts the same executable.
        var kept: [Int: Int] = [:]
        /// Program ids that need a shortcut made.
        var added: [Int] = []
        /// Shortcut app ids to remove.
        var removed: [Int] = []
        /// Programs whose shortcut the user removed in Steam; they stop being
        /// listed.
        var withdrawn: [Int] = []
        /// Programs whose record names a shortcut it no longer wants.
        var forgotten: [Int] = []
        /// Programs whose kept shortcut starts another executable, folder or
        /// arguments than recorded.
        var retargeted: [Int] = []
    }

    /// Reconciles the programs with Steam's list.
    ///
    /// A program keeps its recorded shortcut while Steam lists it; one with
    /// none takes a listed shortcut for its executable before a new one is
    /// made, so a game added by hand is never listed twice. A kept shortcut
    /// with another target is retargeted. An `owned` shortcut no program
    /// wants is removed; the rest of the list is the user's.
    ///
    /// - Parameter fresh: Shortcuts made moments ago, which Steam's list can
    ///   lag behind: they are kept whether listed or not.
    static func plan(
        _ programs: [Program], listed: [Listed], owned: Set<Int>, fresh: Set<Int> = [],
    ) -> Plan {
        let programs = programs.sorted { $0.id < $1.id }
        let listedIDs = Set(listed.map(\.appid))
        let byID = Dictionary(listed.map { ($0.appid, $0) }, uniquingKeysWith: { first, _ in first })
        var plan = Plan()
        var taken = Set<Int>()
        for program in programs where program.wanted {
            guard let shortcut = program.shortcutID else { continue }
            if listedIDs.contains(shortcut) || fresh.contains(shortcut) {
                plan.kept[program.id] = shortcut
                taken.insert(shortcut)
            } else {
                plan.withdrawn.append(program.id)
            }
        }
        for program in programs where program.wanted && program.shortcutID == nil {
            if let match = listed.first(where: { !taken.contains($0.appid) && exeKey($0.exe) == exeKey(program.target.exe) }) {
                plan.kept[program.id] = match.appid
                taken.insert(match.appid)
            } else {
                plan.added.append(program.id)
            }
        }
        var unwanted = owned
        for program in programs where !program.wanted {
            guard let shortcut = program.shortcutID else { continue }
            plan.forgotten.append(program.id)
            unwanted.insert(shortcut)
        }
        plan.removed = unwanted.filter { listedIDs.contains($0) && !taken.contains($0) }.sorted()
        plan.retargeted = programs.filter { program in
            guard let shortcut = plan.kept[program.id], let shown = byID[shortcut] else { return false }
            return !starts(shown, program.target)
        }.map(\.id)
        return plan
    }

    // MARK: - What this app made

    private static let ownedKey = "steamShortcuts"

    /// The shortcuts this app made or took, which it may remove. Kept apart
    /// from the program records so a program removed while the client was
    /// down, or by `sevo`, still loses its shortcut.
    static func owned(in defaults: UserDefaults = Preferences.shared) -> Set<Int> {
        Set((defaults.array(forKey: ownedKey) as? [Int]) ?? [])
    }

    static func setOwned(_ ids: Set<Int>, in defaults: UserDefaults = Preferences.shared) {
        defaults.set(ids.sorted(), forKey: ownedKey)
    }

    // MARK: - Scripts

    /// Steam's shortcuts as JSON `[{appid, exe, startDir, launchOptions}]`,
    /// or null while the client's stores are still loading: a short list
    /// would make every program look withdrawn.
    static let listScript = """
    (async function () {
      if (!(window.App && App.GetServicesInitialized && App.GetServicesInitialized())
          || !window.appStore || !appStore.m_bIsInitialized || !window.appDetailsStore) return null;
      var shortcuts = appStore.allApps.filter(function (app) { return app.BIsShortcut(); });
      var details = await Promise.race([
        Promise.all(shortcuts.map(function (app) { return appDetailsStore.RequestAppDetails(app.appid); })),
        new Promise(function (resolve) { setTimeout(resolve, 4000, null); })
      ]);
      if (!details) return null;
      return JSON.stringify(shortcuts.map(function (app, i) {
        var shown = details[i] || {};
        return {
          appid: app.appid, exe: shown.strShortcutExe || "",
          startDir: shown.strShortcutStartDir || "", launchOptions: shown.strLaunchOptions || ""
        };
      }));
    })()
    """

    /// Makes a shortcut as Steam's "Add a Non-Steam Game" dialog does, then
    /// names and targets it. Answers the new app id, or null.
    static func addScript(name: String, target: Target) -> String {
        """
        (async function () {
          var name = \(JSLiteral.string(name)), exe = \(JSLiteral.string(target.exe));
          var appid = await SteamClient.Apps.AddShortcut(name, exe, "", exe);
          if (typeof appid !== "number" || !appid) return null;
          SteamClient.Apps.SetShortcutName(appid, name);
          \(setTargetCalls(target))
          return String(appid);
        })()
        """
    }

    /// Points an existing shortcut at `target`.
    static func retargetScript(_ shortcutID: Int, _ target: Target) -> String {
        """
        (async function () {
          var appid = \(shortcutID);
          await SteamClient.Apps.SetShortcutExe(appid, \(JSLiteral.string(target.quotedExe)));
          \(setTargetCalls(target))
          return "retargeted";
        })()
        """
    }

    private static func setTargetCalls(_ target: Target) -> String {
        """
        await SteamClient.Apps.SetShortcutStartDir(appid, \(JSLiteral.string(target.quotedStartDir)));
          await SteamClient.Apps.SetShortcutLaunchOptions(appid, \(JSLiteral.string(target.launchOptions)));
        """
    }

    static func removeScript(_ shortcutIDs: [Int]) -> String {
        let ids = shortcutIDs.map(String.init).joined(separator: ",")
        return """
        [\(ids)].forEach(function (appid) { SteamClient.Apps.RemoveShortcut(appid); }), "removed"
        """
    }
}
