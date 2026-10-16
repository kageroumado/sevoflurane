import CryptoKit
import Foundation
import SophonCodecs

/// The checksums and codecs Sophon's files are checked and unpacked with.
nonisolated enum SophonCodec {
    /// md5 of bytes, lowercase hex: the digest Sophon names every chunk,
    /// file and manifest by.
    static func md5(_ data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// md5 of a file, streamed a block at a time.
    static func md5(of file: URL) throws -> String {
        try FileDigest.md5(of: file)
    }

    /// One zstd chunk or manifest, decompressed to the size it is listed at.
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        try Zstd.decompress(data, expectedSize: expectedSize)
    }

    /// Why a diff could not be applied.
    typealias PatchFailure = HPatch.Failure

    /// Applies one file's diff. `old` is nil for a file the diff creates.
    static func patch(old: URL?, diff: URL, to new: URL) throws {
        try HPatch.apply(old: old, diff: diff, to: new)
    }
}
