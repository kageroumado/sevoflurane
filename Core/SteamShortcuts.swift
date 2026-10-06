import Foundation

/// Adopted programs as non-Steam games in Steam's own library, so Big Picture,
/// Steam Input and the overlay reach them the way they reach a game Steam
/// sells.
///
/// The client owns `shortcuts.vdf` and rewrites it from memory, so the list is
/// changed through the client's own calls (`SteamClient.Apps.AddShortcut` and
/// its siblings) on the connection the bridge holds, and the file is never
/// touched. Each shortcut's app id is kept in the program's record; Steam's
/// launch and lifetime events name a shortcut by that id, and the app turns it
/// back into the program's own id before anything else reads it, so a run
/// Steam starts gets the run record, status line and Discord activity a Quick
/// Launch start gets. The env file and the Dock tile need nothing: the engine
/// finds both by the executable's name, whoever started it.
nonisolated enum SteamShortcuts {
    // MARK: - Ids

    /// The type a 64-bit game id carries in bits 24 to 31 for a non-Steam
    /// shortcut (`k_EGameIDTypeShortcut`).
    private static let shortcutType: UInt64 = 2

    /// The bit Steam sets on every shortcut's 32-bit app id.
    private static let shortcutBit: UInt64 = 0x8000_0000

    /// The shortcut app id a Steam event names, if it names one.
    ///
    /// A game action names its app by 64-bit game id: for a shortcut that is
    /// the shortcut's app id in the high word and type 2 in bits 24 to 31. A
    /// lifetime notification names it by the 32-bit app id itself, which
    /// always has its high bit set.
    static func shortcutID(in steamID: String) -> Int? {
        guard let value = UInt64(steamID) else { return nil }
        if value <= UInt64(UInt32.max) {
            return value & shortcutBit != 0 ? Int(value) : nil
        }
        guard (value >> 24) & 0xFF == shortcutType, (value >> 32) & shortcutBit != 0 else { return nil }
        return Int(value >> 32)
    }

    /// The 64-bit game id Steam's calls take for a shortcut, `TerminateApp`
    /// among them.
    static func gameID(shortcutID: Int) -> String {
        String(UInt64(UInt32(truncatingIfNeeded: shortcutID)) << 32 | shortcutType << 24)
    }

    /// The app id behind an id Steam's events carry: the adopted program's own
    /// for a shortcut that is its entry in Steam's library, so a run Steam
    /// starts there is recorded as the program's; the number itself otherwise.
    static func appID(fromSteam steamID: String, aliases: [Int: Int]) -> Int? {
        if let shortcut = shortcutID(in: steamID), let program = aliases[shortcut] {
            return program
        }
        return Int(steamID)
    }

    /// Shortcut app id → adopted program id, for every program Steam lists.
    static func aliases(_ entries: [AdoptedPrograms.Entry]) -> [Int: Int] {
        var aliases: [Int: Int] = [:]
        for entry in entries {
            guard let shortcut = entry.program.steamShortcutID else { continue }
            aliases[shortcut] = entry.id
        }
        return aliases
    }

    /// The store title whose shortcut a `RunGame` call starts, which needs
    /// this launch's program from its store before Steam starts it.
    static func storeProgram(launching gameID: String, in entries: [AdoptedPrograms.Entry]) -> AdoptedPrograms.Entry? {
        guard let shortcut = shortcutID(in: gameID) else { return nil }
        return entries.first { $0.program.steamShortcutID == shortcut && $0.program.store != nil }
    }

    // MARK: - Matching

    /// An executable path as the comparison sees it. Steam keeps a
    /// shortcut's target in quotes and Windows paths ignore case, so neither
    /// may decide whether two paths name one file.
    static func exeKey(_ windowsPath: String) -> String {
        var path = windowsPath.trimmingCharacters(in: .whitespaces)
        if path.count >= 2, path.hasPrefix("\""), path.hasSuffix("\"") {
            path = String(path.dropFirst().dropLast())
        }
        return path.replacingOccurrences(of: "/", with: #"\"#).lowercased()
    }

    /// A start folder as the comparison sees it: ``exeKey(_:)`` with the
    /// closing backslash Steam writes taken off.
    static func folderKey(_ windowsPath: String) -> String {
        var key = exeKey(windowsPath)
        while key.hasSuffix(#"\"#), key.count > 3 {
            key.removeLast()
        }
        return key
    }

    /// A program's arguments as one launch-option line, quoted the way a
    /// Windows command line is split again (`CommandLineToArgvW`): a token
    /// with a space, a tab or a quote in it, or an empty one, is wrapped in
    /// quotes, a quote inside is escaped, and backslashes are doubled where
    /// they come before a quote.
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

    /// What a shortcut starts: its target, its start folder and its launch
    /// options. Paths are plain Windows paths; the scripts quote them the way
    /// Steam keeps a shortcut's own.
    struct Target: Equatable, Sendable {
        let exe: String
        let startDir: String
        let launchOptions: String

        /// The target as Steam keeps it, in quotes.
        var quotedExe: String {
            "\"\(exe)\""
        }

        /// The start folder as Steam keeps it, in quotes and ending in a
        /// backslash.
        var quotedStartDir: String {
            var folder = startDir
            while folder.hasSuffix(#"\"#) {
                folder.removeLast()
            }
            return "\"\(folder)\\\""
        }
    }

    /// A program's target: its executable, the folder its store names or
    /// else the executable's own, and its arguments.
    static func target(_ program: AdoptedProgram) -> Target {
        let folder = program.workingDirectory.map { URL(fileURLWithPath: $0) } ?? program.url.deletingLastPathComponent()
        return Target(
            exe: SteamBottle.windowsPath(for: program.url),
            startDir: SteamBottle.windowsPath(for: folder),
            launchOptions: launchOptions(program.arguments),
        )
    }

    /// Whether a listed shortcut already starts `target`.
    static func starts(_ listed: Listed, _ target: Target) -> Bool {
        exeKey(listed.exe) == exeKey(target.exe)
            && folderKey(listed.startDir) == folderKey(target.startDir)
            && listed.launchOptions.trimmingCharacters(in: .whitespaces)
            == target.launchOptions.trimmingCharacters(in: .whitespaces)
    }

    /// The store launches Steam is starting from a shortcut that carries this
    /// launch's program, Epic's one-time sign-in among its launch options.
    /// The shortcut gets the program as recorded back once Steam has started
    /// the game or given up, and a sync pass leaves it alone until then.
    struct Launches: Sendable {
        private var inFlight: [Int: (shortcut: Int, generation: Int)] = [:]
        private var generation = 0

        /// The shortcuts with a launch in flight.
        var shortcuts: Set<Int> {
            Set(inFlight.values.map(\.shortcut))
        }

        /// Marks a program's shortcut as carrying a launch's program, and
        /// answers the launch's generation for ``settle(_:generation:)``.
        mutating func begin(programID: Int, shortcut: Int) -> Int {
            generation += 1
            inFlight[programID] = (shortcut, generation)
            return generation
        }

        /// Ends a program's launch and answers its shortcut, which gets the
        /// recorded program back; nil when no launch of it is in flight, or
        /// when `generation` names an earlier one.
        mutating func settle(_ programID: Int, generation: Int? = nil) -> Int? {
            guard let launch = inFlight[programID], generation == nil || generation == launch.generation else {
                return nil
            }
            inFlight[programID] = nil
            return launch.shortcut
        }
    }

    // MARK: - The plan

    /// One shortcut in Steam's list: its app id and what it starts.
    struct Listed: Decodable, Equatable, Sendable {
        var appid: Int
        var exe: String
        var startDir = ""
        var launchOptions = ""
    }

    /// One adopted program as a pass weighs it.
    struct Program: Equatable, Sendable {
        let id: Int
        /// What its shortcut starts.
        let target: Target
        /// Whether it belongs in Steam's library: the user wants it there and
        /// it can run under the Steam client.
        let wanted: Bool
        /// The shortcut its record names.
        let shortcutID: Int?
    }

    /// What one pass changes, in Steam's list and in the records.
    struct Plan: Equatable, Sendable {
        /// Program id → the shortcut that is its entry, its record's own or
        /// one already in Steam's list that starts the same executable.
        var kept: [Int: Int] = [:]
        /// Programs that need a shortcut made, by id.
        var added: [Int] = []
        /// Shortcut app ids to take out of Steam's list.
        var removed: [Int] = []
        /// Programs whose shortcut has left Steam's list: the user removed
        /// it there, and the program stops being listed.
        var withdrawn: [Int] = []
        /// Programs whose record names a shortcut it no longer wants.
        var forgotten: [Int] = []
        /// Programs whose kept shortcut starts something other than the
        /// program as recorded: another executable, folder or arguments.
        var retargeted: [Int] = []
    }

    /// Reconciles the programs with Steam's list.
    ///
    /// A program keeps the shortcut its record names while Steam lists it. A
    /// program with none takes a listed shortcut that starts its executable
    /// before a new one is made, so a game the user added to Steam by hand is
    /// never listed twice. A kept shortcut that Steam lists with another
    /// target, start folder or launch options is pointed at the program as
    /// recorded. A shortcut this app made or took (`owned`) that no
    /// program wants any more is removed; the rest of the list is the user's
    /// and stays as it is.
    ///
    /// - Parameters:
    ///   - fresh: Shortcuts made moments ago, which Steam's list can lag
    ///     behind: they are kept whether listed or not.
    ///   - launching: Shortcuts carrying a store launch's program
    ///     (``Launches``), which keep it until the launch settles.
    static func plan(
        _ programs: [Program], listed: [Listed], owned: Set<Int>, fresh: Set<Int> = [], launching: Set<Int> = [],
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
            guard let shortcut = plan.kept[program.id], !launching.contains(shortcut),
                  let shown = byID[shortcut] else { return false }
            return !starts(shown, program.target)
        }.map(\.id)
        return plan
    }

    // MARK: - What this app made

    private static let ownedKey = "steamShortcuts"

    /// The shortcuts this app made or took, which it may remove again. Kept
    /// apart from the program records so a program removed while the client
    /// was down, or by `sevo`, still has its shortcut taken away.
    static func owned(in defaults: UserDefaults = Preferences.shared) -> Set<Int> {
        Set((defaults.array(forKey: ownedKey) as? [Int]) ?? [])
    }

    static func setOwned(_ ids: Set<Int>, in defaults: UserDefaults = Preferences.shared) {
        defaults.set(ids.sorted(), forKey: ownedKey)
    }

    // MARK: - Scripts

    /// Steam's shortcuts as JSON `[{appid, exe, startDir, launchOptions}]`,
    /// or null while the client's
    /// stores are still loading: a list read then would be short, and a short
    /// list would make every program look withdrawn.
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

    /// Makes a shortcut the way Steam's "Add a Non-Steam Game" dialog does,
    /// names it, and gives it the program's start folder and arguments.
    /// Answers the new app id, or null when the client made none.
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

    /// The calls that set a shortcut's start folder and launch options.
    private static func setTargetCalls(_ target: Target) -> String {
        """
        await SteamClient.Apps.SetShortcutStartDir(appid, \(JSLiteral.string(target.quotedStartDir)));
          await SteamClient.Apps.SetShortcutLaunchOptions(appid, \(JSLiteral.string(target.launchOptions)));
        """
    }

    /// Takes shortcuts out of Steam's list.
    static func removeScript(_ shortcutIDs: [Int]) -> String {
        let ids = shortcutIDs.map(String.init).joined(separator: ",")
        return """
        [\(ids)].forEach(function (appid) { SteamClient.Apps.RemoveShortcut(appid); }), "removed"
        """
    }
}
