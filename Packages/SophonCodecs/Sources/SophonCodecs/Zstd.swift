import CZstd
import Foundation

/// zstd decompression of whole frames, the shape Sophon's chunks and
/// manifests arrive in.
public enum Zstd {
    /// Why a frame could not be decompressed.
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    /// Decompresses one or more concatenated frames. `expectedSize` is the
    /// size the manifest promises; the result is refused unless it is exactly
    /// that long.
    public static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
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
