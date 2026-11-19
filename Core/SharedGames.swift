import Foundation

/// Game files shared between bottles: the game's `steamapps/common` directory
/// becomes a symlink into the bottle that has it, and its `appmanifest` is
/// copied, since Steam rewrites it per bottle.
///
/// Steam reads manifests at startup, so a link lands after a client restart.
/// Removing a linked game removes the link and manifest, never the files.
nonisolated enum SharedGames {
    struct Candidate: Identifiable, Sendable, Equatable {
        let appID: Int
        let name: String
        let installdir: String
        /// The other bottle's `steamapps`, where the real files live.
        let sourceSteamapps: URL
        /// Shown with ``sourceEngine``: every engine's default bottle is "Steam".
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

    /// One game installed in the active bottle.
    struct Installed: Sendable, Equatable {
        let appID: Int
        let name: String
        let directory: URL
        /// Steam's own count of the game's size on disk.
        let bytes: Int64
        /// The library's `steamapps` the game's manifest is in.
        let steamapps: URL
    }

    /// Games in other bottles that the active one lacks; first bottle wins.
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

    /// The symlink half of a link, safe while the client runs: Steam ignores
    /// `common/` entries without a manifest. Idempotent.
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

    /// The manifest half. Write it only around a client restart: mid-session
    /// it makes the client's library visibly reshuffle.
    static func writeManifest(_ candidate: Candidate) throws {
        let acf = "appmanifest_\(candidate.appID).acf"
        let target = activeSteamapps.appendingPathComponent(acf)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.copyItem(
            at: candidate.sourceSteamapps.appendingPathComponent(acf),
            to: target,
        )
    }

    /// Undoes a pending link: the symlink only.
    static func removePendingLink(_ candidate: Candidate) throws {
        let target = activeSteamapps
            .appendingPathComponent("common/\(candidate.installdir)")
        guard (try? FileManager.default
            .destinationOfSymbolicLink(atPath: target.path)) != nil else { return }
        try FileManager.default.removeItem(at: target)
    }

    /// Whether the active bottle's copy of this game is a link into another.
    static func isLinked(appID: Int) -> Bool {
        guard let directory = installDirectory(appID: appID) else { return false }
        return (try? FileManager.default
            .destinationOfSymbolicLink(atPath: directory.path)) != nil
    }

    /// Removes the link and the manifest; refuses a real directory.
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

    /// Where a game's files are in the active bottle, or `nil`.
    static func installDirectory(appID: Int) -> URL? {
        installed(appID: appID)?.directory
    }

    /// A game's name and files from its manifest, or `nil` when not installed.
    static func installed(appID: Int) -> Installed? {
        for steamapps in SteamLibraries.steamapps() {
            let manifest = steamapps.appendingPathComponent("appmanifest_\(appID).acf")
            if let game = installed(manifest: manifest, in: steamapps) { return game }
        }
        return nil
    }

    /// Every game installed in the active bottle, from Steam's manifests;
    /// `steamapps` narrows it to one library.
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

    /// The first value of `key` in an ACF manifest's `"key" "value"` pairs.
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
