import CryptoKit
import Foundation

/// File digests in lower-case hex.
nonisolated enum FileDigest {
    /// Streaming block size; game files exceed 500 MB.
    private static let blockSize = 4 << 20

    static func sha256(of file: URL) throws -> String {
        try hash(SHA256.self, of: file)
    }

    static func md5(of file: URL) throws -> String {
        try hash(Insecure.MD5.self, of: file)
    }

    /// One autorelease pool per block: `read(upToCount:)` returns autoreleased
    /// data, and without the pool a 133 GB installation check holds every block.
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
