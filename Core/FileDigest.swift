import CryptoKit
import Foundation

/// File digests, lower-case hex: the sha256 a pinned download is checked
/// against and the engine's renderer provenance is written in, and the md5
/// Sophon names every game file by.
nonisolated enum FileDigest {
    /// Block size for streaming a file through a hash: engine tarballs are
    /// hundreds of MB and the largest game file is over 500 MB.
    private static let blockSize = 4 << 20

    static func sha256(of file: URL) throws -> String {
        try hash(SHA256.self, of: file)
    }

    static func md5(of file: URL) throws -> String {
        try hash(Insecure.MD5.self, of: file)
    }

    /// Each block is read inside its own autorelease pool, because
    /// `FileHandle.read(upToCount:)` returns autoreleased data and the loops
    /// that check a whole game installation never return to a run loop that
    /// would drain it: without the pool, a 133 GB check holds every block.
    private static func hash<H: HashFunction>(_: H.Type, of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = H()
        while try autoreleasepool(invoking: {
            guard let block = try handle.read(upToCount: blockSize), !block.isEmpty else { return false }
            hasher.update(data: block)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
