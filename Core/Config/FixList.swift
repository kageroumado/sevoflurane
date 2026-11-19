import CryptoKit
import Foundation

/// The per-game fixes this Mac knows: the built-in table
/// (``KnownFixes/all``), then the community database's list
/// (`GET /v1/fixes.json`, curated from "plays with fixes" reports).
///
/// Applied without a click, so taken only signed: `fixes.json.sig` is a base64
/// Ed25519 signature over the exact bytes from the pinned key
/// (`kagerou sevostats publish-fixes`). A list whose `serial` is below the
/// highest taken (``Preferences/fixListSerial``) is refused, so a retired fix
/// cannot be replayed. Both are checked on arrival and at every cache read,
/// and values pass ``FixValues/admitted(_:)``. The cache is refetched weekly
/// with its `ETag`; a failed or unsigned list leaves the cached one standing.
nonisolated enum FixList {
    static let url = StatsUploader.baseURL.appendingPathComponent("fixes.json")
    static let signatureURL = StatsUploader.baseURL.appendingPathComponent("fixes.json.sig")

    /// Raw 32-byte Ed25519 public key, base64. The private half is
    /// `infrastructure/publish/keys/sevostats-fixes-ed25519.pem`.
    static let pinnedPublicKeyBase64 = "1fIfskR2Jkg6c3H8KV340kgJegbs/v2se8EHS7nM6dQ="

    static var pinnedKey: Curve25519.Signing.PublicKey? {
        Data(base64Encoded: pinnedPublicKeyBase64).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
    }

    /// Where a refused list is reported; the app's event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

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

    /// Every fix, the built-in table first and winning; the cached list counts
    /// only while it verifies.
    static var current: [KnownFix] {
        guard let body = try? Data(contentsOf: cacheURL),
              let signature = try? Data(contentsOf: cachedSignatureURL),
              case let .taken(list) = verdict(on: body, signature: signature, highestSerial: Preferences.fixListSerial)
        else { return KnownFixes.all }
        return merged(builtIn: KnownFixes.all, served: list.fixes)
    }

    struct SignedList: Equatable {
        let serial: Int
        let issued: Date
        let fixes: [KnownFix]
    }

    enum Verdict: Equatable {
        case taken(SignedList)
        case unsigned
        /// Signed, without a readable serial and issued time.
        case malformed
        case older(serial: Int, highest: Int)
        /// Issued more than ``issuedTolerance`` from now.
        case fromTheFuture(Date)
    }

    /// Whether `body` is a list to take: signed by `key`, a serial at least
    /// `highestSerial`, and issued no later than a day from `now`.
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

    /// The signed payload; entries that fail to decode or set nothing are
    /// dropped one by one.
    private struct Listing: Decodable {
        let serial: Int
        let issued: String
        let fixes: [Entry]
    }

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

    /// The built-in fixes, then each served one minus the keys a built-in fix
    /// for the same target sets; an emptied entry is dropped.
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

    /// Refetches a stale or missing list, keeping it only when
    /// ``verdict(on:signature:highestSerial:key:now:)`` takes it.
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
