import CryptoKit
import Foundation

/// The per-game fixes this Mac knows: the built-in table
/// (``KnownFixes/all``), then the community database's list
/// (`GET /v1/fixes.json`, curated from "plays with fixes" reports).
///
/// A first launch applies the list without a click, so it is taken only
/// signed: `fixes.json.sig` is the raw Ed25519 signature over the list's
/// exact bytes, base64, from the key pinned here, made on the admin's Mac
/// (`kagerou sevostats publish-fixes`). The signature is checked when the
/// list arrives and again at every read of the cache, and every entry's
/// values then pass ``FixValues/admitted(_:)``.
///
/// The cache is asked for again once it is a week old with the `ETag` it
/// came with, so an unchanged list costs a 304. A list that cannot be
/// reached, or arrives without a valid signature, leaves the cached one
/// standing, and a Mac that never took one has the built-in table alone.
nonisolated enum FixList {
    static let url = StatsUploader.baseURL.appendingPathComponent("fixes.json")
    static let signatureURL = StatsUploader.baseURL.appendingPathComponent("fixes.json.sig")

    /// Raw 32-byte Ed25519 public key, base64. The private half is
    /// `infrastructure/publish/keys/sevostats-fixes-ed25519.pem`.
    static let pinnedPublicKeyBase64 = "1fIfskR2Jkg6c3H8KV340kgJegbs/v2se8EHS7nM6dQ="

    static var pinnedKey: Curve25519.Signing.PublicKey? {
        Data(base64Encoded: pinnedPublicKeyBase64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// Where a refused or unreachable list is reported. The app points it at
    /// its event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    /// As long as the compat tables: the list changes when a fix is promoted,
    /// a few times a month.
    static let maxAge = GameCompatService.maxAge

    static var cacheURL: URL {
        GameCompatService.cacheRoot.appendingPathComponent("fixes.json")
    }

    static var cachedSignatureURL: URL {
        GameCompatService.cacheRoot.appendingPathComponent("fixes.json.sig")
    }

    private static var tagURL: URL {
        GameCompatService.cacheRoot.appendingPathComponent("fixes.etag")
    }

    /// Every fix, the built-in table first: where both name a value for the
    /// same game, the built-in one is the one that counts. The cached list
    /// counts only while its signature verifies.
    static var current: [KnownFix] {
        let served = (try? Data(contentsOf: cacheURL)).flatMap { body in
            (try? Data(contentsOf: cachedSignatureURL)).map { verified(body, signature: $0) }
        } ?? []
        return merged(builtIn: KnownFixes.all, served: served)
    }

    /// The entries of `body` when `signature` is the pinned key's over it;
    /// nothing otherwise.
    static func verified(
        _ body: Data, signature: Data, key: Curve25519.Signing.PublicKey? = pinnedKey,
    ) -> [KnownFix] {
        guard let key, (try? EngineSignature.verify(body, signatureFile: signature, subject: "fixes.json", key: key)) != nil
        else { return [] }
        return served(from: body)
    }

    // MARK: - Reading a served list

    /// The entries of a signed list this version can read, each with only
    /// the values ``FixValues/admitted(_:)`` lets through. An entry naming a
    /// value this version does not know is left out on its own, and one left
    /// setting nothing is left out too.
    private static func served(from data: Data) -> [KnownFix] {
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
            let exe = exe?.lowercased()
            switch (appid, exe) {
            case let (appid?, nil) where appid > 0 && appid <= Int(Int32.max):
                break
            case let (nil, exe?) where FixValues.isValidExePattern(exe):
                break
            default:
                return nil
            }
            let title = FixValues.plainLine(title, limit: 120)
            let reason = FixValues.plainLine(reason, limit: 600)
            guard !title.isEmpty, !reason.isEmpty else { return nil }
            return KnownFix(
                appID: appid, exePattern: exe, title: title, values: FixValues.admitted(values), reason: reason,
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
    /// missing, and keeps a new one only when its signature verifies.
    /// Failures leave the cache as it is.
    static func refreshIfStale(session: URLSession = .shared) async {
        let manager = FileManager.default
        let modified = (try? manager.attributesOfItem(atPath: cacheURL.path))?[.modificationDate] as? Date
        if let modified, Date.now.timeIntervalSince(modified) < maxAge { return }
        var request = URLRequest(url: url, timeoutInterval: 15)
        if modified != nil, let tag = try? String(contentsOf: tagURL, encoding: .utf8),
           tag.wholeMatch(of: /"[0-9a-f]{1,64}"/) != nil {
            request.setValue(tag, forHTTPHeaderField: "If-None-Match")
        }
        guard let (body, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 304:
            try? manager.setAttributes([.modificationDate: Date.now], ofItemAtPath: cacheURL.path)
        case 200:
            guard let (signature, signed) = try? await session.data(from: signatureURL),
                  (signed as? HTTPURLResponse)?.statusCode == 200, signature.count <= 1024,
                  let key = pinnedKey,
                  (try? EngineSignature.verify(body, signatureFile: signature, subject: "fixes.json", key: key)) != nil
            else {
                log("fix list: the downloaded list has no valid signature from the fixes key; ignored")
                return
            }
            try? manager.createDirectory(at: GameCompatService.cacheRoot, withIntermediateDirectories: true)
            try? signature.write(to: cachedSignatureURL, options: .atomic)
            try? body.write(to: cacheURL, options: .atomic)
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                try? Data(tag.utf8).write(to: tagURL, options: .atomic)
            } else {
                try? manager.removeItem(at: tagURL)
            }
            log("fix list: \(served(from: body).count) signed entries taken")
        default:
            break
        }
    }
}
