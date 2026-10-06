import CryptoKit
import Foundation

/// The per-game fixes this Mac knows: the built-in table
/// (``KnownFixes/all``), then the community database's list
/// (`GET /v1/fixes.json`, curated from "plays with fixes" reports).
///
/// A first launch applies the list without a click, so it is taken only
/// signed: `fixes.json.sig` is the raw Ed25519 signature over the list's
/// exact bytes, base64, from the key pinned here, made on the admin's Mac
/// (`kagerou sevostats publish-fixes`). The signed payload carries a
/// `serial` that grows with every publish and the time it was `issued`; the
/// highest serial taken is remembered (``Preferences/fixListSerial``) and a
/// list below it is refused, so an old signed list cannot be replayed to
/// bring back a fix that was retired. The signature and the serial are
/// checked when the list arrives and again at every read of the cache, and
/// every entry's values then pass ``FixValues/admitted(_:)``.
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

    /// How far ahead of this Mac's clock a list may say it was issued.
    static let issuedTolerance: TimeInterval = 24 * 3600

    /// Every fix, the built-in table first: where both name a value for the
    /// same game, the built-in one is the one that counts. The cached list
    /// counts only while its signature verifies and its serial is still the
    /// highest taken.
    static var current: [KnownFix] {
        guard let body = try? Data(contentsOf: cacheURL),
              let signature = try? Data(contentsOf: cachedSignatureURL),
              case let .taken(list) = verdict(on: body, signature: signature, highestSerial: Preferences.fixListSerial)
        else { return KnownFixes.all }
        return merged(builtIn: KnownFixes.all, served: list.fixes)
    }

    /// A signed list as it was read.
    struct SignedList: Equatable {
        let serial: Int
        let issued: Date
        let fixes: [KnownFix]
    }

    /// What a list is worth to this Mac.
    enum Verdict: Equatable {
        case taken(SignedList)
        /// No valid signature from the fixes key over the bytes.
        case unsigned
        /// Signed, without a serial and an issued time this version reads.
        case malformed
        /// Signed, and older than a list this Mac took.
        case older(serial: Int, highest: Int)
        /// Signed, and issued more than ``issuedTolerance`` from now.
        case fromTheFuture(Date)
    }

    /// Whether `body` is a list to take: a signature from `key` over its
    /// exact bytes, a serial at least `highestSerial` (the same list again
    /// is taken), and an issued time no later than a day from `now`.
    static func verdict(
        on body: Data, signature: Data, highestSerial: Int,
        key: Curve25519.Signing.PublicKey? = pinnedKey, now: Date = .now,
    ) -> Verdict {
        guard let key, (try? EngineSignature.verify(body, signatureFile: signature, subject: "fixes.json", key: key)) != nil
        else { return .unsigned }
        guard let listing = try? JSONDecoder().decode(Listing.self, from: body),
              let issued = try? Date(listing.issued, strategy: .iso8601)
        else { return .malformed }
        guard listing.serial >= highestSerial else { return .older(serial: listing.serial, highest: highestSerial) }
        guard issued.timeIntervalSince(now) <= issuedTolerance else { return .fromTheFuture(issued) }
        return .taken(SignedList(
            serial: listing.serial, issued: issued,
            fixes: listing.fixes.compactMap(\.fix).filter(\.values.hasSettings),
        ))
    }

    // MARK: - Reading a served list

    /// The signed payload. Each entry keeps only the values
    /// ``FixValues/admitted(_:)`` lets through; an entry naming a value this
    /// version does not know is left out on its own, and one left setting
    /// nothing is left out too.
    private struct Listing: Decodable {
        let serial: Int
        let issued: String
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
    /// missing, and keeps a new one only when ``verdict(on:signature:highestSerial:key:now:)``
    /// takes it. Failures leave the cache as it is.
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
            let fetched = try? await session.data(from: signatureURL)
            guard let (signature, signed) = fetched, (signed as? HTTPURLResponse)?.statusCode == 200,
                  signature.count <= 1024
            else {
                log("fix list: no signature beside the downloaded list; ignored")
                return
            }
            let verdict = verdict(on: body, signature: signature, highestSerial: Preferences.fixListSerial)
            guard case let .taken(list) = verdict else {
                log("fix list: the downloaded list was refused (\(verdict)); the cached one stands")
                return
            }
            Preferences.fixListSerial = list.serial
            try? manager.createDirectory(at: GameCompatService.cacheRoot, withIntermediateDirectories: true)
            try? signature.write(to: cachedSignatureURL, options: .atomic)
            try? body.write(to: cacheURL, options: .atomic)
            if let tag = http.value(forHTTPHeaderField: "ETag") {
                try? Data(tag.utf8).write(to: tagURL, options: .atomic)
            } else {
                try? manager.removeItem(at: tagURL)
            }
            log("fix list: serial \(list.serial) taken, \(list.fixes.count) entries")
        default:
            break
        }
    }
}
