import CryptoKit
import Foundation

/// The trust anchor for everything the engine pipeline downloads: an Ed25519
/// public key compiled into the app, whose private half signs every engine
/// release (`dormison/build-macos/publish-engine.sh`). A release asset's
/// signature is the raw 64-byte Ed25519 signature over the asset's bytes,
/// base64, in a sibling file named `<asset>.sig`; the manifest is signed the
/// same way (`engine.json.sig`). Verification happens before a manifest is
/// trusted and before a tarball is opened, so a compromised release feed or
/// asset store cannot hand the app an engine it did not sign.
///
/// The key is a source constant rather than an Info.plist entry: `sevo`
/// shares these sources and runs from `Contents/Helpers` with no bundle of its
/// own, and one definition cannot drift.
nonisolated enum EngineSignature {
    /// Raw 32-byte Ed25519 public key, base64. The private half is
    /// `infrastructure/publish/keys/dormison-ed25519.pem`.
    static let pinnedPublicKeyBase64 = "7uDuIZdCZyobjZcPL12zL+UNOCpHSvLXvVRFHA7bzzA="

    /// Release assets are accepted only from these repositories, over HTTPS.
    static let allowedAssetPathPrefixes = [
        "/kageroumado/dormison/releases/download/",
        "/kageroumado/sevoflurane/releases/download/",
    ]

    static var pinnedKey: Curve25519.Signing.PublicKey {
        get throws {
            guard let raw = Data(base64Encoded: pinnedPublicKeyBase64),
                  let key = try? Curve25519.Signing.PublicKey(rawRepresentation: raw)
            else { throw Failure.keyMissing }
            return key
        }
    }

    /// The signature file that covers `asset`, by the one naming rule.
    static func signatureURL(for asset: URL) -> URL {
        URL(string: asset.absoluteString + ".sig") ?? asset.appendingPathExtension("sig")
    }

    /// HTTPS, on github.com, under one of the release-download paths we publish to.
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

    /// Verifies `signatureFile` over `message` with the pinned key.
    static func verify(
        _ message: some DataProtocol, signatureFile: Data, subject: String,
        key: Curve25519.Signing.PublicKey? = nil,
    ) throws {
        let key = try key ?? pinnedKey
        let signature = try signature(fromFile: signatureFile)
        guard key.isValidSignature(signature, for: message) else {
            throw Failure.signatureInvalid(subject)
        }
    }

    /// Verifies a file on disk without reading it into memory twice: the
    /// engine tarball is hundreds of MB, and a mapped read is what CryptoKit
    /// hashes from.
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
                "\(subject) does not carry a valid signature from the engine key"
            case let .urlNotAllowed(url):
                "\(url.absoluteString) is not a release asset of a kageroumado repository"
            }
        }
    }
}
