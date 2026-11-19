import CryptoKit
import DeviceCheck
import Foundation

/// The key the community database knows this Mac by.
///
/// A Secure Enclave P-256 key made at opt-in, stored as its
/// ``SecureEnclave/P256/Signing/PrivateKey/dataRepresentation``, a blob only
/// this Mac's enclave can use. The install id is derived from the public key,
/// so the server can check it against the signature; a reset makes a new one.
nonisolated struct StatsIdentity: Sendable {
    let key: SecureEnclave.P256.Signing.PrivateKey

    /// The public key as SubjectPublicKeyInfo DER, which is what the server parses.
    var publicKeyDER: Data {
        key.publicKey.derRepresentation
    }

    var installID: String {
        Self.installID(publicKeyDER: publicKeyDER)
    }

    /// `base32(SHA-256(DER))`, lowercase, the first 26 characters (130 bits).
    static func installID(publicKeyDER: Data) -> String {
        String(Base32.encode(Data(SHA256.hash(data: publicKeyDER))).prefix(26))
    }

    /// An ECDSA P-256 signature over SHA-256 of `body`, DER-encoded.
    func sign(_ body: Data) throws -> Data {
        try key.signature(for: body).derRepresentation
    }

    // MARK: - Storage

    static var isAvailable: Bool {
        SecureEnclave.isAvailable
    }

    /// The stored key, or `nil` when missing or restored from another Mac.
    static func load(from url: URL = StatsStore.identityURL) -> StatsIdentity? {
        guard let blob = try? Data(contentsOf: url),
              let key = try? SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: blob)
        else { return nil }
        return StatsIdentity(key: key)
    }

    static func create(at url: URL = StatsStore.identityURL) throws -> StatsIdentity {
        let key = try SecureEnclave.P256.Signing.PrivateKey()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try key.dataRepresentation.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return StatsIdentity(key: key)
    }

    // MARK: - Apple's word that the key is on a real Mac

    /// What registration carries besides the key: an App Attest attestation and
    /// a DeviceCheck token. The server grades `attested`, `device` or
    /// `unverified`; the token is sent even with App Attest, since its bit
    /// tells a reinstall from a new Mac.
    struct Evidence: Sendable {
        var appAttestKeyID: String?
        var attestation: Data?
        var deviceToken: Data?

        /// The tier this evidence can earn, for the log.
        var tier: String {
            switch (attestation, deviceToken) {
            case (_?, _): "attested"
            case (nil, _?): "device"
            case (nil, nil): "unverified"
            }
        }
    }

    /// App Attest signs `SHA-256(publicKeyDER ‖ challenge)`, so the
    /// attestation vouches for this key and for this registration only.
    func evidence(challenge: Data) async -> Evidence {
        var evidence = Evidence()
        let service = DCAppAttestService.shared
        if service.isSupported {
            var step = "generateKey"
            do {
                let keyID = try await service.generateKey()
                step = "attestKey"
                let clientDataHash = Data(SHA256.hash(data: publicKeyDER + challenge))
                evidence.attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
                evidence.appAttestKeyID = keyID
            } catch {
                let nsError = error as NSError
                if step == "attestKey", nsError.domain == DCError.errorDomain, nsError.code == DCError.invalidKey.rawValue {
                    // Under Reduced or Permissive Security the key generates but cannot attest.
                    StatsUploader.log("App Attest: this Mac cannot attest (App Attest needs Full Security and SIP) — registering without it")
                } else {
                    StatsUploader.log("App Attest declined at \(step): \(nsError.domain) \(nsError.code) \(nsError.userInfo)")
                }
            }
        }
        if DCDevice.current.isSupported {
            do {
                evidence.deviceToken = try await DCDevice.current.generateToken()
            } catch {
                StatsUploader.log("DeviceCheck declined: \(error.localizedDescription)")
            }
        }
        return evidence
    }
}

/// RFC 4648 base32 without padding, lowercase.
nonisolated enum Base32 {
    private static let alphabet = Array("abcdefghijklmnopqrstuvwxyz234567")

    static func encode(_ data: Data) -> String {
        var output = ""
        var buffer = 0
        var bits = 0
        for byte in data {
            buffer = (buffer << 8) | Int(byte)
            bits += 8
            while bits >= 5 {
                output.append(alphabet[(buffer >> (bits - 5)) & 31])
                bits -= 5
            }
        }
        if bits > 0 {
            output.append(alphabet[(buffer << (5 - bits)) & 31])
        }
        return output
    }
}
