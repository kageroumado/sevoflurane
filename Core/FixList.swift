import Foundation

/// The per-game fixes this Mac knows: the built-in table
/// (``KnownFixes/all``), then the community database's list
/// (`GET /v1/fixes`, curated from "plays with fixes" reports).
///
/// The served list is a file in the compat cache, asked for again once it is
/// a week old with the `ETag` it came with, so an unchanged list costs a 304.
/// A list that cannot be reached leaves the cached one standing, and a Mac
/// that never reached it has the built-in table alone.
nonisolated enum FixList {
    static let url = StatsUploader.baseURL.appendingPathComponent("fixes")

    /// As long as the compat tables: the list changes when a fix is promoted,
    /// a few times a month.
    static let maxAge = GameCompatService.maxAge

    static var cacheURL: URL {
        GameCompatService.cacheRoot.appendingPathComponent("fixes.json")
    }

    private static var tagURL: URL {
        GameCompatService.cacheRoot.appendingPathComponent("fixes.etag")
    }

    /// Every fix, the built-in table first: where both name a value for the
    /// same game, the built-in one is the one that counts.
    static var current: [KnownFix] {
        let served = (try? Data(contentsOf: cacheURL)).map(served(from:)) ?? []
        return merged(builtIn: KnownFixes.all, served: served)
    }

    // MARK: - Reading a served list

    /// The entries of a served list this version can read. An entry naming a
    /// value this version does not know is left out on its own, and one that
    /// sets nothing this version has is left out too.
    static func served(from data: Data) -> [KnownFix] {
        guard let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [] }
        return listing.fixes.compactMap(\.fix).filter(\.values.hasSettings)
    }

    private struct Listing: Decodable {
        let fixes: [Entry]
    }

    /// One served entry, `nil` where it does not decode.
    private struct Entry: Decodable {
        let fix: KnownFix?

        init(from decoder: any Decoder) throws {
            fix = (try? Served(from: decoder))?.fix
        }
    }

    private struct Served: Decodable {
        let appid: Int?
        let exe: String?
        let title: String
        let values: ConfigValues
        let reason: String

        var fix: KnownFix? {
            guard (appid == nil) != (exe == nil) else { return nil }
            return KnownFix(
                appID: appid, exePattern: exe?.lowercased(), title: title, values: values, reason: reason,
            )
        }
    }

    // MARK: - Merging

    /// The built-in fixes, then each served one without the keys a built-in
    /// fix for the same game or the same executable pattern already sets.
    /// A served entry left with nothing is dropped, which is what the
    /// server's copies of the built-in table come to.
    static func merged(builtIn: [KnownFix], served: [KnownFix]) -> [KnownFix] {
        builtIn + served.compactMap { fix in
            let covered = builtIn
                .filter { $0.appID == fix.appID && $0.exePattern == fix.exePattern }
                .reduce(into: Set<String>()) { keys, own in keys.formUnion(own.values.fields.keys) }
            guard !covered.isEmpty else { return fix }
            let rest = fix.values.fields.filter { !covered.contains($0.key) }
            guard let values = ConfigValues(fields: rest), values.hasSettings else { return nil }
            return KnownFix(
                appID: fix.appID, exePattern: fix.exePattern, title: fix.title, values: values, reason: fix.reason,
            )
        }
    }

    // MARK: - Fetching

    /// Asks for the list when the cached one is older than ``maxAge`` or
    /// missing. Failures leave the cache as it is.
    static func refreshIfStale(session: URLSession = .shared) async {
        let manager = FileManager.default
        let modified = (try? manager.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let modified, Date.now.timeIntervalSince(modified) < maxAge { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if modified != nil, let tag = try? String(contentsOf: tagURL, encoding: .utf8) {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 304:
            try? manager.setAttributes([.modificationDate: Date.now], ofItemAtPath: cacheURL.path)
        case 200 where (try? JSONDecoder().decode(Listing.self, from: data)) != nil:
            try? manager.createDirectory(at: GameCompatService.cacheRoot, withIntermediateDirectories: true)
            try? data.write(to: cacheURL, options: .atomic)
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                try? Data(tag.utf8).write(to: tagURL, options: .atomic)
            } else {
                try? manager.removeItem(at: tagURL)
            }
        default:
            break
        }
    }
}
