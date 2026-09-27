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

    /// The NW.js build of an installed game, by app id.
    static func detect(appID: Int) -> NWJSInfo? {
        SharedGames.installDirectory(appID: appID).flatMap(detect(inDirectory:))
    }

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
    /// top. Three levels reaches every layout seen in the wild without
    /// walking a multi-gigabyte asset tree.
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
        return scan(directory, depth: 3)
    }

    /// greenworks' Steam Cloud calls, the part of its surface the bridge to
    /// the bottle does not carry.
    private static let cloudCalls = ["saveTextToFile", "saveFilesToCloud", "readTextFromFile"]

    /// Whether the game's own scripts call greenworks for cloud storage. Only
    /// asked of a game that bundles greenworks at all, and only of its
    /// scripts — a plugin directory is a few megabytes of text next to a
    /// multi-gigabyte asset tree.
    private static func usesSteamCloud(inDirectory directory: URL) -> Bool {
        func scan(_ url: URL, depth: Int) -> Bool {
            for entry in InstallDirectory.entries(in: url) {
                if entry.isDirectory {
                    if depth > 1, scan(entry.url, depth: depth - 1) { return true }
                    continue
                }
                guard entry.name.lowercased().hasSuffix(".js"),
                      let text = try? String(contentsOf: entry.url, encoding: .utf8)
                else { continue }
                if cloudCalls.contains(where: text.contains) { return true }
            }
            return false
        }
        return scan(directory, depth: 4)
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
