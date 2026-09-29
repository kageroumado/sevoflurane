import CHPatch
import Foundation

/// Applies HDiffPatch compressed diffs (`HDIFF13&zstd`), the format every
/// file of a Sophon update arrives in.
public enum HPatch {
    /// Why a diff could not be applied.
    public enum Failure: Error, Equatable, CustomStringConvertible {
        case openOld, openDiff, openNew, badDiff, unsupportedCompression, oldSize, failed

        public var description: String {
            switch self {
            case .openOld: "the old file could not be opened"
            case .openDiff: "the diff could not be opened"
            case .openNew: "the new file could not be created"
            case .badDiff: "the diff is not an HDiffPatch compressed diff"
            case .unsupportedCompression: "the diff uses a compressor other than zstd"
            case .oldSize: "the old file is not the size the diff was made against"
            case .failed: "patching failed part way"
            }
        }
    }

    /// Writes `old` patched by `diff` to `new`. A nil `old` patches against
    /// an empty file, which is how a diff carries a file with no older copy.
    public static func apply(old: URL?, diff: URL, to new: URL) throws {
        let result = sophon_hpatch_apply(old?.path, diff.path, new.path)
        switch result {
        case SOPHON_HPATCH_OK: return
        case SOPHON_HPATCH_OPEN_OLD: throw Failure.openOld
        case SOPHON_HPATCH_OPEN_DIFF: throw Failure.openDiff
        case SOPHON_HPATCH_OPEN_NEW: throw Failure.openNew
        case SOPHON_HPATCH_BAD_DIFF: throw Failure.badDiff
        case SOPHON_HPATCH_UNSUPPORTED_COMPRESSION: throw Failure.unsupportedCompression
        case SOPHON_HPATCH_OLD_SIZE: throw Failure.oldSize
        default: throw Failure.failed
        }
    }
}
