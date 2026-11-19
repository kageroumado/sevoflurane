import Foundation

/// What a game's own NW.js build says about itself: enough to pick the matching macOS runtime,
/// write its wrapper package, and know whether achievements need the bottle-side stub.
nonisolated struct NWJSInfo: Codable, Equatable, Sendable {
    /// The NW.js the game ships, as its own binary declares it ("0.29.0").
    var version: String
    /// The directory holding the game's `package.json`, a unix path.
    var dir: String
    /// The game's entry page, a unix path.
    var main: String
    /// "RPG Maker MV", "RPG Maker MZ", or absent for a plain NW.js app.
    var flavor: String?
    /// Whether the game bundles greenworks, the node module that talks to `steam_api.dll`, so its
    /// achievements need the stub.
    var greenworks: Bool
    /// Whether the game's own code stores anything through greenworks' Steam Cloud calls. The
    /// bridge reports failure for cloud writes, so such a game keeps its progress only on the wine
    /// runner.
    var greenworksCloud: Bool?
    /// `package.json`'s `name`, the directory NW.js keeps localStorage and IndexedDB under; an
    /// empty name means NW.js' default, `nwjs`.
    var packageName: String

    /// One line for a listing: `nwjs 0.29.0 · RPG Maker MV · greenworks no`.
    var summary: String {
        "nwjs \(version)"
            + (flavor.map { " · \($0)" } ?? "")
            + " · greenworks \(greenworks ? "yes" : "no")"
            + (greenworksCloud == true ? " (uses Steam Cloud)" : "")
    }

    /// What a user must know before switching this game to the native runner.
    var caution: String? {
        greenworksCloud == true
            ? "this game stores progress through greenworks' Steam Cloud calls, which the "
            + "native runner cannot carry — its saves on disk are unaffected, but anything "
            + "it keeps in the cloud stops being written"
            : nil
    }
}

/// Finds the games that are NW.js applications behind a Windows exe (RPG Maker MV and MZ titles, or
/// anything else on NW.js): Chromium apps whose only Windows part is the loader, which macOS can
/// run natively through ``NWJSRunner``.
nonisolated enum NWJSGames {
    /// What `main` has to name for the directory to be an NW.js application.
    private static let pageExtensions: Set<String> = ["html", "htm"]

    // MARK: - Detecting

    /// The NW.js build in a game directory, or `nil`. An unpacked `package.nw` directory is read
    /// like any other; a `package.nw` archive answers `nil`, since the runner's wrapper needs the
    /// entry page on disk.
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
        // `main` is relative to the package and may carry a URL-style query.
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

    /// NW.js' default application name, and so an unnamed application's browsing-data directory.
    static let defaultPackageName = "nwjs"

    /// Which RPG Maker runtime ships beside the game data decides where saves live: MV under `www`,
    /// MZ beside the package.
    private static func flavor(inDirectory directory: URL) -> String? {
        let manager = FileManager.default
        func exists(_ relative: String) -> Bool {
            manager.fileExists(atPath: directory.appendingPathComponent(relative).path)
        }
        if exists("www/js/rpg_core.js") { return "RPG Maker MV" }
        if exists("js/rmmz_core.js") || exists("www/js/rmmz_core.js") { return "RPG Maker MZ" }
        return nil
    }

    /// Whether a `greenworks*.node` binding sits within five levels: the deepest layout seen is an
    /// unpacked `package.nw/www/js/libs/` (OMORI's binding is in `www/js/libs/`, four down).
    /// Folders are listed, never read.
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

    /// greenworks' Steam Cloud calls, which the bridge to the bottle does not carry.
    private static let cloudCalls = ["saveTextToFile", "saveFilesToCloud", "readTextFromFile"]

    /// A cloud call named as a whole identifier, which also catches `['saveTextToFile']` and
    /// `.call` or `.apply` through it.
    private static let cloudMention = try? NSRegularExpression(
        pattern: "(?<![\\w$])(?:\(cloudCalls.joined(separator: "|")))(?![\\w$])",
    )

    /// A named function definition: `name = function (`, `name: function (` or `function name(`;
    /// group 1 or 2 is the name.
    private static let namedDefinition = try? NSRegularExpression(
        pattern: "([A-Za-z_$][\\w$]*)\\s*[=:]\\s*function\\s*\\(|function\\s+([A-Za-z_$][\\w$]*)\\s*\\(",
    )

    /// Whether the game's own scripts (within four levels) use greenworks for cloud storage.
    ///
    /// `greenworks.js` itself is skipped, since every vendored copy carries the cloud functions. A
    /// mention inside a named function counts only when that function is referenced beyond its
    /// definition, so an unused plugin wrapper (Archeia Steamworks' `saveTextToCloud`, untouched by
    /// OMORI) does not count, while one bound as a handler (`this.onSavefileOk.bind(this)`) does.
    /// Scripts are read one at a time, never held together.
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

    /// The function each cloud-call mention sits in, in text order: the innermost named definition
    /// open at the mention, or `nil` outside any, which runs whenever the script does. Tracks
    /// braces in one pass.
    static func cloudCallers(in text: String) -> [String?] {
        let utf16 = Array(text.utf16)
        let whole = NSRange(location: 0, length: utf16.count)
        // A pattern that failed to compile counts as a top-level mention, which keeps the game's
        // saves in the bottle.
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

    /// Mentions of `name` as a whole identifier less its definitions; summed over a game's scripts,
    /// a positive total means something calls or hands on the function.
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

    /// The NW.js version of a game's loader DLL: its version resource, else, since RPG Maker's
    /// builds zero every field, the `process.versions.nw` string NW.js compiles into its resource
    /// bundle.
    static func version(ofLoader loader: URL) -> String? {
        if let declared = PEResources.read(loader)?.productVersion,
           !declared.isEmpty, declared != "0.0.0.0", declared != "0.0.0" {
            return declared
        }
        return embeddedVersion(inLoader: loader)
    }

    private static let versionNeedle = Data("process.versions['nw'] = '".utf8)

    /// Scans the loader for the version literal in overlapping chunks, since the file is tens of
    /// megabytes and the needle can straddle a boundary.
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

    /// Runs detection for one game and records it in the settings store. Also records the game's
    /// executable when the directory holds just one exe, the one Steam starts, so per-game settings
    /// need not wait for a first launch.
    @discardableResult
    static func record(appID: Int) -> NWJSInfo? {
        guard let game = SharedGames.installed(appID: appID) else { return nil }
        let found = detect(inDirectory: game.directory)
        var values = GameConfig.game(appID)
        // A native run's window and Dock tile are titled with Steam's name.
        if values.nwjs != found || values.name != game.name {
            // A native runner chosen without the cloud warning (by the default or a player) is
            // reset to undecided once detection finds cloud use, keeping the game in the bottle; a
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

    /// Detection over the installed library, run once at client start.
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
