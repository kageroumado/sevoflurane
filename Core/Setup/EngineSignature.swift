import CryptoKit
import Foundation

/// The trust anchor for engine downloads: pinned Ed25519 public keys whose
/// private halves sign releases (`dormison/build-macos/publish-engine.sh`).
/// A signature from any pinned key is accepted. Each asset, and the manifest
/// (`engine.json.sig`), has a sibling `<asset>.sig` holding the base64 raw
/// 64-byte signature, verified before the manifest is trusted or a tarball
/// opened.
///
/// The keys are source constants because `sevo` shares these sources and
/// runs from `Contents/Helpers` with no bundle of its own.
nonisolated enum EngineSignature {
    /// Raw 32-byte Ed25519 public keys, base64. The private halves stay
    /// outside every repository. A new key is pinned for a few releases
    /// before anything is signed with it, and the manifest's `minAppVersion`
    /// turns away an app that pins only the key before.
    static let pinnedPublicKeysBase64 = [
        // dormison-ed25519-2026-10.pem, pinned since 1.8.0.
        "5sQ6cDQSthaMVF3fZEVs9hTvnn0j2WZ2OuKOeNvBmPM=",
    ]

    /// Release assets are accepted only from these repositories, over HTTPS.
    static let allowedAssetPathPrefixes = [
        "/kageroumado/dormison/releases/download/",
    ]

    static var pinnedKeys: [Curve25519.Signing.PublicKey] {
        get throws {
            let keys = pinnedPublicKeysBase64.compactMap { encoded in
                Data(base64Encoded: encoded).flatMap { try? Curve25519.Signing.PublicKey(rawRepresentation: $0) }
            }
            guard keys.count == pinnedPublicKeysBase64.count else { throw Failure.keyMissing }
            return keys
        }
    }

    /// The signature file that covers `asset`, by the one naming rule.
    static func signatureURL(for asset: URL) -> URL {
        URL(string: asset.absoluteString + ".sig") ?? asset.appendingPathExtension("sig")
    }

    /// HTTPS, github.com, under an allowed release-download path.
    static func isAllowedAssetURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              url.host()?.lowercased() == "github.com",
              url.user == nil, url.password == nil
        else { return false }
        let path = url.path(percentEncoded: false)
        return allowedAssetPathPrefixes.contains { path.hasPrefix($0) }
    }

    /// Decodes a `.sig` file: base64 (whitespace tolerated) of exactly 64 bytes.
    static func signature(fromFile data: Data) throws -> Data {
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let signature = Data(base64Encoded: text), signature.count == 64 else {
            throw Failure.signatureMalformed
        }
        return signature
    }

    /// Verifies with `key`, or with any pinned key.
    static func verify(
        _ message: some DataProtocol, signatureFile: Data, subject: String,
        key: Curve25519.Signing.PublicKey? = nil,
    ) throws {
        try verify(message, signatureFile: signatureFile, subject: subject, keys: key.map { [$0] } ?? pinnedKeys)
    }

    /// Verifies `signatureFile` over `message` with any of `keys`.
    static func verify(
        _ message: some DataProtocol, signatureFile: Data, subject: String, keys: [Curve25519.Signing.PublicKey],
    ) throws {
        let signature = try signature(fromFile: signatureFile)
        guard keys.contains(where: { $0.isValidSignature(signature, for: message) }) else {
            throw Failure.signatureInvalid(subject)
        }
    }

    /// Verifies a file through a mapped read: the tarball is hundreds of MB.
    static func verify(
        file: URL, signatureFile: Data, key: Curve25519.Signing.PublicKey? = nil,
    ) throws {
        let bytes = try Data(contentsOf: file, options: .mappedIfSafe)
        try verify(bytes, signatureFile: signatureFile, subject: file.lastPathComponent, key: key)
    }

    /// Fetches the `.sig` beside `asset` and verifies `file` against it.
    @concurrent
    static func verify(file: URL, asset: URL, key: Curve25519.Signing.PublicKey? = nil) async throws {
        let signatureURL = signatureURL(for: asset)
        guard isAllowedAssetURL(signatureURL) else { throw Failure.urlNotAllowed(signatureURL) }
        let signatureFile = try await fetchSignature(signatureURL)
        try verify(file: file, signatureFile: signatureFile, key: key)
    }

    static func fetchSignature(_ url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200, data.count <= 1024 else {
            throw Failure.signatureMissing(url)
        }
        return data
    }

    enum Failure: Error, CustomStringConvertible, Equatable {
        case keyMissing
        case signatureMissing(URL)
        case signatureMalformed
        case signatureInvalid(String)
        case urlNotAllowed(URL)

        var description: String {
            switch self {
            case .keyMissing:
                "the engine signing key is not pinned in this build"
            case let .signatureMissing(url):
                "no signature at \(url.absoluteString)"
            case .signatureMalformed:
                "the signature file is not a base64 Ed25519 signature"
            case let .signatureInvalid(subject):
                "\(subject) does not carry a valid signature from an engine key"
            case let .urlNotAllowed(url):
                "\(url.absoluteString) is not a release asset of a kageroumado repository"
            }
        }
    }
}
