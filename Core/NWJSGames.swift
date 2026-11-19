import Foundation

/// What a game's own NW.js build says about itself: enough to pick the macOS
/// runtime that matches it, to write the wrapper package it is started
/// through, and to know whether achievements need the bottle-side stub.
nonisolated struct NWJSInfo: Codable, Equatable, Sendable {
    /// The NW.js the game ships, as its own binary declares it ("0.29.0").
    var version: String
    /// The directory holding the game's `package.json`, a unix path.
    var dir: String
    /// The game's entry page, a unix path.
    var main: String
    /// "RPG Maker MV", "RPG Maker MZ", or absent for a plain NW.js app.
    var flavor: String?
    /// Whether the game bundles greenworks, the node module that talks to
    /// `steam_api.dll` — the games whose achievements need the stub.
    var greenworks: Bool
    /// Whether the game's own code stores anything through greenworks' Steam
    /// Cloud calls. The bridge to the bottle carries achievements and stats
    /// and reports failure for the cloud rather than pretending to write, so
    /// such a game keeps its progress only on the wine runner.
    var greenworksCloud: Bool?
    /// `package.json`'s `name`, which is the directory NW.js keeps
    /// localStorage and IndexedDB under. NW.js' own default is `nwjs`, which
    /// is what an empty name in the file means.
    var packageName: String

    /// One line for a listing: `nwjs 0.29.0 · RPG Maker MV · greenworks no`.
    var summary: String {
        "nwjs \(version)"
            + (flavor.map { " · \($0)" } ?? "")
            + " · greenworks \(greenworks ? "yes" : "no")"
            + (greenworksCloud == true ? " (uses Steam Cloud)" : "")
    }

    /// What a user has to know before switching this game to the native
    /// runner, or `nil` when there is nothing to say.
    var caution: String? {
        greenworksCloud == true
            ? "this game stores progress through greenworks' Steam Cloud calls, which the "
            + "native runner cannot carry — its saves on disk are unaffected, but anything "
            + "it keeps in the cloud stops being written"
            : nil
    }
}

/// Finds the games that are NW.js applications wearing a Windows exe: an
/// RPG Maker MV or MZ title, or anything else built on NW.js. Such a game is
/// a Chromium app whose only Windows part is the loader, so macOS can run it
/// natively — detection is what decides a game is eligible, and
/// ``NWJSRunner`` is what arranges the native run.
nonisolated enum NWJSGames {
    /// What `main` has to name for the directory to be an NW.js application.
    private static let pageExtensions: Set<String> = ["html", "htm"]

    // MARK: - Detecting

    /// The NW.js build in a game directory, or `nil` when it is an ordinary
    /// Windows game.
    ///
    /// A `package.nw` **archive** is deliberately not resolved: its entry page
    /// lives inside the zip, and the wrapper package the runner writes needs a
    /// path on disk. An unpacked `package.nw` directory is read like any other.
    static func detect(inDirectory directory: URL) -> NWJSInfo? {
        let manager = FileManager.default
        let loaders = ["nw.dll", "nw_elf.dll"]
        let loader = loaders
            .map { directory.appendingPathComponent($0) }
            .first { manager.fileExists(atPath: $0.path) }
        guard let loader else { return nil }

        let unpacked = directory.appendingPathComponent("package.nw")
        var isDirectory: ObjCBool = false
        let packageRoot = manager.fileExists(atPath: unpacked.path, isDirectory: &isDirectory)
            && isDirectory.boolValue ? unpacked : directory
        let packageURL = packageRoot.appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: packageURL),
              let package = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let main = package["main"] as? String
        else { return nil }
        // `main` is relative to the package, and may carry a query string the
        // way a URL does.
        let page = String(main.prefix { $0 != "?" && $0 != "#" })
        guard pageExtensions.contains((page as NSString).pathExtension.lowercased()) else {
            return nil
        }
        let pageURL = packageRoot.appendingPathComponent(page)
        guard manager.fileExists(atPath: pageURL.path) else { return nil }

        let name = (package["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let greenworks = hasGreenworks(inDirectory: directory)
        return NWJSInfo(
            version: version(ofLoader: loader) ?? "",
            dir: packageRoot.path,
            main: pageURL.path,
            flavor: flavor(inDirectory: packageRoot),
            greenworks: greenworks,
            greenworksCloud: greenworks ? usesSteamCloud(inDirectory: packageRoot) : false,
            packageName: name ?? defaultPackageName,
        )
    }

    /// NW.js' own name for an application that does not give one, and so the
    /// directory its browsing data lands in.
    static let defaultPackageName = "nwjs"

    /// RPG Maker ships its own runtime beside the game data, and which one it
    /// is decides where saves live — MV keeps them under `www`, MZ beside the
    /// package.
    private static func flavor(inDirectory directory: URL) -> String? {
        let manager = FileManager.default
        func exists(_ relative: String) -> Bool {
            manager.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }
        if exists("www/js/rpg_core.js") { return "RPG Maker MV" }
        if exists("js/rmmz_core.js") || exists("www/js/rmmz_core.js") { return "RPG Maker MZ" }
        return nil
    }

    /// Greenworks is a native node module, so a game that has one carries a
    /// `greenworks*.node` — under `node_modules`, beside a plugin, or at the
    /// top. Five levels reaches the deepest layout seen in the wild, an
    /// unpacked `package.nw/www/js/libs/` (OMORI keeps its binding in
    /// `www/js/libs/`, four down), while only listing the asset folders at
    /// that depth, never reading them.
    private static func hasGreenworks(inDirectory directory: URL) -> Bool {
        func scan(_ url: URL, depth: Int) -> Bool {
            for entry in InstallDirectory.entries(in: url) {
                let name = entry.name.lowercased()
                if name.hasPrefix("greenworks"), name.hasSuffix(".node") { return true }
                guard depth > 1, entry.isDirectory else { continue }
                if scan(entry.url, depth: depth - 1) { return true }
            }
            return false
        }
        return scan(directory, depth: 5)
    }

    /// greenworks' Steam Cloud calls, the part of its surface the bridge to
    /// the bottle does not carry.
    private static let cloudCalls = ["saveTextToFile", "saveFilesToCloud", "readTextFromFile"]

    /// Any mention of a cloud call as a whole identifier: a call, a call with
    /// a space before its parenthesis, a bracketed `['saveTextToFile']`, a
    /// `.call` or `.apply` through it.
    private static let cloudMention = try? NSRegularExpression(
        pattern: "(?<![\\w$])(?:\(cloudCalls.joined(separator: "|")))(?![\\w$])",
    )

    /// A named function definition: `name = function (`, `name: function (`
    /// or `function name(`. Group 1 or 2 is the name.
    private static let namedDefinition = try? NSRegularExpression(
        pattern: "([A-Za-z_$][\\w$]*)\\s*[=:]\\s*function\\s*\\(|function\\s+([A-Za-z_$][\\w$]*)\\s*\\(",
    )

    /// Whether the game's own scripts use greenworks for cloud storage. Only
    /// asked of a game that bundles greenworks at all, and only of its
    /// scripts — a plugin directory is a few megabytes of text next to a
    /// multi-gigabyte asset tree.
    ///
    /// greenworks' own `greenworks.js` is left out: every game that vendors
    /// the module carries its cloud functions whether or not it calls them. A
    /// mention inside a named function counts only when that function is
    /// referenced anywhere beyond its definition, which keeps a plugin's
    /// unused wrapper (Archeia Steamworks' `saveTextToCloud`, which OMORI
    /// never touches) from deciding the runner, while a wrapper bound as a
    /// handler (`this.onSavefileOk.bind(this)`) still counts. Each script is
    /// read once per pass and dropped, so a large `node_modules` is never held
    /// in memory.
    private static func usesSteamCloud(inDirectory directory: URL) -> Bool {
        let scripts = scriptURLs(inDirectory: directory, depth: 4)
            .filter { $0.lastPathComponent.lowercased() != "greenworks.js" }
        var wrappers: Set<String> = []
        for url in scripts {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for caller in cloudCallers(in: text) {
                guard let caller else { return true }
                wrappers.insert(caller)
            }
        }
        guard !wrappers.isEmpty else { return false }
        var balance: [String: Int] = [:]
        for url in scripts {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for name in wrappers { balance[name, default: 0] += referenceBalance(of: name, in: text) }
        }
        return balance.values.contains { $0 > 0 }
    }

    private static func scriptURLs(inDirectory directory: URL, depth: Int) -> [URL] {
        var found: [URL] = []
        for entry in InstallDirectory.entries(in: directory) {
            if entry.isDirectory {
                if depth > 1 { found += scriptURLs(inDirectory: entry.url, depth: depth - 1) }
            } else if entry.name.lowercased().hasSuffix(".js") {
                found.append(entry.url)
            }
        }
        return found
    }

    /// The function each cloud-call mention in a script sits in, in text
    /// order: the innermost named definition whose body is open at the
    /// mention. `nil` for a mention outside any named function, which runs
    /// whenever the script does. One pass over the text, tracking braces.
    static func cloudCallers(in text: String) -> [String?] {
        let utf16 = Array(text.utf16)
        let whole = NSRange(location: 0, length: utf16.count)
        // A pattern that failed to compile reads as a mention outside any
        // function: the answer that keeps a game's saves in the bottle.
        guard let cloudMention, let namedDefinition else { return [nil] }
        let mentions = cloudMention.matches(in: text, range: whole).map(\.range.location)
        guard !mentions.isEmpty else { return [] }
        let definitions: [(end: Int, name: String)] = namedDefinition.matches(in: text, range: whole)
            .compactMap { match in
                let group = match.range(at: 1).location != NSNotFound ? match.range(at: 1) : match.range(at: 2)
                guard let range = Range(group, in: text) else { return nil }
                return (NSMaxRange(match.range), String(text[range]))
            }

        let open = UInt16(UInt8(ascii: "{")), close = UInt16(UInt8(ascii: "}"))
        var callers: [String?] = []
        var stack: [(name: String, depth: Int)] = []
        var pending: String?
        var depth = 0
        var nextDefinition = 0
        var nextMention = 0
        for (offset, unit) in utf16.enumerated() {
            while nextDefinition < definitions.count, definitions[nextDefinition].end <= offset {
                pending = definitions[nextDefinition].name
                nextDefinition += 1
            }
            while nextMention < mentions.count, mentions[nextMention] == offset {
                callers.append(stack.last?.name)
                nextMention += 1
            }
            if nextMention == mentions.count { break }
            if unit == open {
                depth += 1
                if let name = pending {
                    stack.append((name, depth))
                    pending = nil
                }
            } else if unit == close {
                if stack.last?.depth == depth { stack.removeLast() }
                depth -= 1
            }
        }
        return callers
    }

    /// How many times `text` mentions `name` as a whole identifier, less the
    /// times it defines it. Summed over a game's scripts, a positive total is
    /// a function something calls or hands on.
    static func referenceBalance(of name: String, in text: String) -> Int {
        let escaped = NSRegularExpression.escapedPattern(for: name)
        guard let mention = try? NSRegularExpression(pattern: "(?<![\\w$])\(escaped)(?![\\w$])"),
              let definition = try? NSRegularExpression(
                  pattern: "(?<![\\w$])\(escaped)\\s*[=:]\\s*function\\s*\\(|function\\s+\(escaped)\\s*\\(",
              )
        else { return 1 }
        let range = NSRange(location: 0, length: (text as NSString).length)
        return mention.numberOfMatches(in: text, range: range)
            - definition.numberOfMatches(in: text, range: range)
    }

    // MARK: - The version a game was built against

    /// The NW.js version of a game's loader DLL. The version resource is the
    /// documented place and is read first, through ``PEResources``; RPG
    /// Maker's own builds ship one with every field zeroed, so the fallback is
    /// the string NW.js writes into its resource bundle for
    /// `process.versions.nw` — the same number the game itself would report at
    /// runtime.
    static func version(ofLoader loader: URL) -> String? {
        if let declared = PEResources.read(loader)?.productVersion,
           !declared.isEmpty, declared != "0.0.0.0", declared != "0.0.0" {
            return declared
        }
        return embeddedVersion(inLoader: loader)
    }

    private static let versionNeedle = Data("process.versions['nw'] = '".utf8)

    /// Scans the loader for the literal NW.js compiles its version into.
    /// Chunked with an overlap, because the file is tens of megabytes and the
    /// needle can straddle a boundary.
    private static func embeddedVersion(inLoader loader: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: loader) else { return nil }
        defer { try? handle.close() }
        let chunkSize = 4 << 20
        let overlap = versionNeedle.count + 32
        var carry = Data()
        while let chunk = try? handle.read(upToCount: chunkSize), !chunk.isEmpty {
            var window = carry
            window.append(chunk)
            if let range = window.firstRange(of: versionNeedle) {
                let tail = window[range.upperBound...].prefix(24)
                let digits = tail.prefix { $0 != UInt8(ascii: "'") }
                let version = String(decoding: digits, as: UTF8.self)
                if !version.isEmpty { return version }
            }
            carry = Data(window.suffix(overlap))
        }
        return nil
    }

    // MARK: - Recording what was found

    /// Runs detection for one game and records it in the settings store, so
    /// the runner switch and the listings read it without touching disk
    /// again. Also seeds the game's executable when the directory names it
    /// unambiguously — an NW.js game keeps one exe beside its loader, which
    /// is the one Steam starts, so a per-game setting need not wait for a
    /// first launch to learn it.
    @discardableResult
    static func record(appID: Int) -> NWJSInfo? {
        guard let game = SharedGames.installed(appID: appID) else { return nil }
        let found = detect(inDirectory: game.directory)
        var values = GameConfig.game(appID)
        // Steam's own name for the game, which is what a native run's window
        // and Dock tile are titled after.
        if values.nwjs != found || values.name != game.name {
            // A native runner chosen while detection showed no Steam Cloud
            // use, by the default or by a player who was never warned, was
            // chosen on wrong facts once detection finds it: the game goes
            // back to undecided, which keeps a cloud game in the bottle. A
            // choice made after the warning stands.
            if values.runner == GameRunner.nwjs, found?.caution != nil,
               values.nwjs?.caution == nil {
                values.runner = nil
                values.nwjsRuntime = nil
                NWJSRunner.log("nwjs: app \(appID) stores progress in Steam Cloud — "
                    + "it runs in the bottle again")
            }
            values.nwjs = found
            values.name = game.name
            GameConfig.setGame(appID, values)
        }
        if found != nil, let exe = soleExecutable(inDirectory: game.directory) {
            GameConfig.noteExecutable(exe, forApp: appID)
        }
        return found
    }

    /// Detection over the whole installed library, for the app to run once at
    /// client start. Cheap: a directory listing and, for the NW.js games, one
    /// scan of a loader each.
    static func recordLibrary() {
        for game in SharedGames.installedGames() {
            record(appID: game.appID)
        }
    }

    private static func soleExecutable(inDirectory directory: URL) -> String? {
        let executables = InstallDirectory.entries(in: directory)
            .map(\.name)
            .filter { $0.lowercased().hasSuffix(".exe") }
        return executables.count == 1 ? executables[0] : nil
    }
}
