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
        let present = installedAppIDs(in: activeSteamapps)
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
                          .appendingPathComponent("common/\(fields.installdir)").path)
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

    static func installedAppIDs(in steamapps: URL) -> Set<Int> {
        Set(manifests(in: steamapps).compactMap { read(manifest: $0)?.appID })
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
        guard let directory = linkedDirectory(appID: appID) else { return false }
        return (try? FileManager.default
            .destinationOfSymbolicLink(atPath: directory.path)) != nil
    }

    /// Removes the link and the manifest. Refuses a real directory — only
    /// the source bottle uninstalls the actual files.
    static func unlink(appID: Int) throws {
        guard let directory = linkedDirectory(appID: appID),
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

    private static func linkedDirectory(appID: Int) -> URL? {
        let manifest = activeSteamapps.appendingPathComponent("appmanifest_\(appID).acf")
        guard let fields = read(manifest: manifest) else { return nil }
        return activeSteamapps.appendingPathComponent("common/\(fields.installdir)")
    }

    // MARK: - ACF plumbing

    private static func manifests(in steamapps: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(
            at: steamapps, includingPropertiesForKeys: nil,
        )) ?? []).filter {
            $0.lastPathComponent.hasPrefix("appmanifest_") && $0.pathExtension == "acf"
        }
    }

    /// The fields worth having out of an ACF: a flat `"key" "value"` format,
    /// so a full VDF parser would be ceremony.
    private static func read(
        manifest url: URL,
    ) -> (appID: Int, name: String, installdir: String, bytes: Int64)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        func value(_ key: String) -> String? {
            guard let range = text.range(of: "\"\(key)\"") else { return nil }
            let rest = text[range.upperBound...]
            guard let open = rest.firstIndex(of: "\""),
                  let close = rest[rest.index(after: open)...].firstIndex(of: "\"")
            else { return nil }
            return String(rest[rest.index(after: open) ..< close])
        }
        guard let id = value("appid").flatMap(Int.init),
              let name = value("name"),
              let installdir = value("installdir") else { return nil }
        return (id, name, installdir, value("SizeOnDisk").flatMap(Int64.init) ?? 0)
    }

    private struct LinkError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
