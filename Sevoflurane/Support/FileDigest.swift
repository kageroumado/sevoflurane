import CryptoKit
import Foundation

/// The sha256 of a file, lower-case hex — the shape a pinned download is
/// checked against and the engine's renderer provenance is written in.
///
/// Read a megabyte at a time, because the files this is asked about include a
/// 96 MB installer and a 40 MB renderer DLL.
nonisolated enum FileDigest {
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
