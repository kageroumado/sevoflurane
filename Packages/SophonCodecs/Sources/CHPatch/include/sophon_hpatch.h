#ifndef SOPHON_HPATCH_H
#define SOPHON_HPATCH_H

#include <stdint.h>

/// How applying an HDiffPatch compressed diff ended.
typedef enum {
    SOPHON_HPATCH_OK = 0,
    /// The old file could not be opened.
    SOPHON_HPATCH_OPEN_OLD = 1,
    /// The diff file could not be opened.
    SOPHON_HPATCH_OPEN_DIFF = 2,
    /// The new file could not be created.
    SOPHON_HPATCH_OPEN_NEW = 3,
    /// The diff is not an HDiffPatch compressed diff (`HDIFF13&...`).
    SOPHON_HPATCH_BAD_DIFF = 4,
    /// The diff's payload uses a compressor other than zstd or none.
    SOPHON_HPATCH_UNSUPPORTED_COMPRESSION = 5,
    /// The old file's size is not the one the diff was made against.
    SOPHON_HPATCH_OLD_SIZE = 6,
    /// Patching failed part way: a read, a write or the decompressor.
    SOPHON_HPATCH_FAILED = 7,
} sophon_hpatch_result;

/// Applies the compressed diff at `diff_path` to `old_path` and writes the
/// result to `new_path`. A NULL `old_path` patches against an empty file,
/// which is how HoYoverse's Sophon diffs carry a file that has no older copy.
sophon_hpatch_result sophon_hpatch_apply(const char *old_path, const char *diff_path,
                                         const char *new_path);

#endif
