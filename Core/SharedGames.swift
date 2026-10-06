import Foundation

/// Game files shared between bottles, one link at a time: the game's
/// directory in `steamapps/common` becomes a symlink into the bottle that
/// already has it, and its `appmanifest` is copied (per-bottle state Steam
/// rewrites, so never shared). One copy on disk, no second download —
/// exactly what testing a game on another engine needs.
///
/// Steam reads the manifests at startup, so a link lands after the client
/// restarts. Removing a linked game removes the link and the manifest,
/// never the files behind them — those belong to the source bottle.
nonisolated enum SharedGames {
    struct Candidate: Identifiable, Sendable, Equatable {
        let appID: Int
        let name: String
        let installdir: String
        /// The other bottle's `steamapps`, where the real files live.
        let sourceSteamapps: URL
        /// Where the files live, said the way a user tells bottles apart —
        /// every engine names its default bottle "Steam", so the bottle
        /// name alone reads as a stutter.
        let sourceBottle: String
        let sourceEngine: String
        let bytes: Int64
        var id: Int { appID }
    }

    static func steamapps(inBottle bottle: URL) -> URL {
        SteamBottle.steamRoot(inBottle: bottle).appendingPathComponent("steamapps")
    }

    static var activeSteamapps: URL {
        steamapps(inBottle: SteamBottle.root)
    }

    /// One game installed in the active bottle, in whichever of Steam's
    /// libraries holds it.
    struct Installed: Sendable, Equatable {
        let appID: Int
        let name: String
        let directory: URL
        /// Steam's own count of the game's size on disk.
        let bytes: Int64
        /// The library's `steamapps` the game's manifest is in.
        let steamapps: URL
    }

    /// Games installed in other bottles (any engine's) that the active
    /// bottle doesn't already have — one candidate per app, first bottle
    /// found wins.
    static func linkable() -> [Candidate] {
        let active = SteamBottle.root.standardizedFileURL
        let engines: [Engine] = [.crossover, .crossoverPreview]
            + SetupProbe.managedEngineVersions().map { .managed(version: $0) }
        var seenBottles: Set<String> = []
        var found: [Candidate] = []
        for engine in engines {
            for bottle in SetupProbe.bottles(for: engine)
                where bottle.url.standardizedFileURL != active {
                guard seenBottles.insert(bottle.url.standardizedFileURL.path).inserted
                else { continue }
                found += candidates(
                    inBottleAt: bottle.url, named: bottle.name,
                    engine: engine.description,
                )
            }
        }
        let present = installedAppIDs
        var seenApps: Set<Int> = []
        return found
            .filter { !present.contains($0.appID) && seenApps.insert($0.appID).inserted }
            .sorted { $0.name.lowercased() < $1.name.lowercased() }
    }

    private static func candidates(
        inBottleAt bottle: URL, named name: String, engine: String,
    ) -> [Candidate] {
        let steamapps = steamapps(inBottle: bottle)
        return manifests(in: steamapps).compactMap { manifest in
            guard let fields = read(manifest: manifest),
                  FileManager.default.fileExists(
                      atPath: steamapps
                          .appendingPathComponent("common/\(fields.installdir)").path,
                  )
            else { return nil }
            return Candidate(
                appID: fields.appID,
                name: fields.name,
                installdir: fields.installdir,
                sourceSteamapps: steamapps,
                sourceBottle: name,
                sourceEngine: engine,
                bytes: fields.bytes,
            )
        }
    }

    /// Every app with a manifest in any of the active bottle's libraries.
    static var installedAppIDs: Set<Int> {
        Set(SteamLibraries.steamapps().flatMap(manifests(in:)).compactMap { read(manifest: $0)?.appID })
    }

    /// The inert half of a link: the game directory's symlink. Steam pays
    /// no attention to `common/` entries it has no manifest for, so this is
    /// safe while the client runs. Idempotent — a link left by an earlier
    /// session is reused.
    static func linkGameFiles(_ candidate: Candidate) throws {
        let common = activeSteamapps.appendingPathComponent("common")
        try FileManager.default.createDirectory(
            at: common, withIntermediateDirectories: true,
        )
        let source = candidate.sourceSteamapps
            .appendingPathComponent("common/\(candidate.installdir)")
        let target = common.appendingPathComponent(candidate.installdir)
        if let existing = try? FileManager.default
            .destinationOfSymbolicLink(atPath: target.path) {
            if existing == source.path { return }
            try FileManager.default.removeItem(at: target)
        }
        try FileManager.default.createSymbolicLink(
            at: target, withDestinationURL: source,
        )
    }

    /// The half Steam notices: the manifest. Written only around a client
    /// restart — a manifest landing mid-session trips the client's own
    /// library watcher into a visible wobble.
    static func writeManifest(_ candidate: Candidate) throws {
        let acf = "appmanifest_\(candidate.appID).acf"
        let target = activeSteamapps.appendingPathComponent(acf)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(
            at: candidate.sourceSteamapps.appendingPathComponent(acf),
            to: target,
        )
    }

    /// Undoes a pending link — the symlink only, since no manifest was
    /// written yet.
    static func removePendingLink(_ candidate: Candidate) throws {
        let target = activeSteamapps
            .appendingPathComponent("common/\(candidate.installdir)")
        guard (try? FileManager.default
            .destinationOfSymbolicLink(atPath: target.path)) != nil else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// Whether the active bottle's copy of this game is a link into another
    /// bottle — the distinction between "remove the link" and "uninstall".
    static func isLinked(appID: Int) -> Bool {
        guard let directory = installDirectory(appID: appID) else { return false }
        return (try? FileManager.default
            .destinationOfSymbolicLink(atPath: directory.path)) != nil
    }

    /// Removes the link and the manifest. Refuses a real directory — only
    /// the source bottle uninstalls the actual files.
    static func unlink(appID: Int) throws {
        guard let directory = installDirectory(appID: appID),
              (try? FileManager.default
                  .destinationOfSymbolicLink(atPath: directory.path)) != nil
        else {
            throw LinkError(message: "app \(appID) isn't a linked game")
        }
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.removeItem(
            at: activeSteamapps.appendingPathComponent("appmanifest_\(appID).acf"),
        )
    }

    /// Where a game's files are in the active bottle, whether they are the
    /// bottle's own or a link into another's. `nil` when the app is not
    /// installed here.
    static func installDirectory(appID: Int) -> URL? {
        installed(appID: appID)?.directory
    }

    /// What Steam calls a game and where its files are, from its manifest in
    /// whichever library holds it. `nil` when the app is not installed here.
    static func installed(appID: Int) -> Installed? {
        for steamapps in SteamLibraries.steamapps() {
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            if let game = installed(manifest: manifest, in: steamapps) { return game }
        }
        return nil
    }

    /// Every game installed in the active bottle, across all of Steam's
    /// libraries, from the manifests Steam keeps — the library as it stands on
    /// disk, readable without the client. `steamapps` narrows it to one.
    static func installedGames(in steamapps: URL? = nil) -> [Installed] {
        let libraries = steamapps.map { [$0] } ?? SteamLibraries.steamapps()
        return libraries.flatMap { library in
            manifests(in: library).compactMap { installed(manifest: $0, in: library) }
        }
    }

    private static func installed(manifest: URL, in steamapps: URL) -> Installed? {
        guard let fields = read(manifest: manifest) else { return nil }
        let directory = steamapps.appendingPathComponent("common/\(fields.installdir)")
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        return Installed(
            appID: fields.appID, name: fields.name, directory: directory,
            bytes: fields.bytes, steamapps: steamapps,
        )
    }

    // MARK: - ACF plumbing

    private static func manifests(in steamapps: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: steamapps, includingPropertiesForKeys: nil,
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf"
        }
    }

    private static func read(
        manifest url: URL,
    ) -> (appID: Int, name: String, installdir: String, bytes: Int64)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func value(_ key: String) -> String? { manifestValue(key, in: text) }
        guard let id = value("appid").flatMap(Int.init),
              let name = value("name"),
              let installdir = value("installdir") else { return nil }
        return (id, name, installdir, value("SizeOnDisk").flatMap(Int64.init) ?? 0)
    }

    /// The first value of `key` in an ACF manifest: a flat `"key" "value"`
    /// format at the top, so a full VDF parser would be ceremony.
    static func manifestValue(_ key: String, in text: String) -> String? {
        guard let range = text.range(of: "\"\(key)\"") else { return nil }
        let rest = text[range.upperBound...]
        guard let open = rest.firstIndex(of: "\""),
              let close = rest[rest.index(after: open)...].firstIndex(of: "\"")
        else { return nil }
        return String(rest[rest.index(after: open) ..< close])
    }

    private struct LinkError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
