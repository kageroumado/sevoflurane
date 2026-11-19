import CZstd
import Foundation

/// zstd decompression of whole frames, the shape Sophon's chunks and
/// manifests arrive in.
public enum Zstd {
    /// Why a frame could not be decompressed.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// The largest result taken: chunks and manifests run to megabytes.
    public static let maximumSize = 1 << 30

    /// Decompresses one or more concatenated frames. `expectedSize` is the
    /// size the manifest promises; the result is refused unless it is exactly
    /// that long.
    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        // The size is a manifest's word, and it is allocated up front.
        guard (0 ... maximumSize).contains(expectedSize) else {
            throw Failure(description: "a decompressed size of \(expectedSize) bytes is not a chunk's")
        }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in
                ZSTD_decompress(out.baseAddress, expectedSize, input.baseAddress, data.count)
            }
        }
        if ZSTD_isError(written) != 0 {
            throw Failure(description: String(cString: ZSTD_getErrorName(written)))
        }
        guard written == expectedSize else {
            throw Failure(description: "decompressed to \(written) bytes, expected \(expectedSize)")
        }
        return output
    }
}
