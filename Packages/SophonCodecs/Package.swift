// swift-tools-version: 6.2
import PackageDescription

/// The two codecs HoYoverse's Sophon downloads need: zstd, for every chunk and
/// manifest, and HDiffPatch's patcher, for the diffs an update is made of.
/// Both are vendored, decompression and patching only.
let package = Package(
    name: "SophonCodecs",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "SophonCodecs", targets: ["SophonCodecs"]),
    ],
    targets: [
        // zstd v1.5.7 (facebook/zstd f8745da), lib/common and lib/decompress.
        .target(
            name: "CZstd",
            cSettings: [
                .define("ZSTD_DISABLE_ASM", to: "1"),
                .define("ZSTD_LEGACY_SUPPORT", to: "0"),
                .define("ZSTD_TRACE", to: "0"),
                .define("DEBUGLEVEL", to: "0"),
            ],
        ),
        // HDiffPatch (sisong/HDiffPatch 3b9dca7), libHDiffPatch/HPatch, single-threaded.
        .target(
            name: "CHPatch",
            dependencies: ["CZstd"],
            cSettings: [
                .define("_IS_USED_MULTITHREAD", to: "0"),
                .define("_IS_NEED_DIR_DIFF_PATCH", to: "0"),
            ],
        ),
        .target(name: "SophonCodecs", dependencies: ["CZstd", "CHPatch"]),
    ],
)
