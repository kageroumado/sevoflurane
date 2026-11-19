import CryptoKit
import Foundation

/// Byte-for-byte fixes to a D3DMetal build that crashes a game, applied to
/// the shared store's copy; the Wine tree gets it at the next staging.
///
/// Each patch is pinned to one build's SHA-256 and to the exact bytes it
/// replaces. The untouched binary is kept as `D3DMetal.unpatched`, the
/// framework is re-signed ad hoc, and reinstalling the toolkit restores
/// Apple's.
nonisolated enum D3DMetalPatches {
    struct Patch: Sendable {
        /// What the log names it by.
        let name: String
        /// The SHA-256 of the build it applies to, before any patch.
        let build: String
        /// The file offset of the first replaced byte, which is also the
        /// address `otool` prints (`__TEXT` starts at file offset 0).
        let offset: Int
        let original: [UInt8]
        let replacement: [UInt8]
    }

    /// D3DMetal 4.0 beta 2: `D3D11Device::CheckMultisampleQualityLevels1`
    /// (tail-called by `CheckMultisampleQualityLevels`) rejects only format 0,
    /// then reads `_dxgi_info[Format]` (0x58 bytes an entry, 191 entries)
    /// unbounded. Unity asks with `DXGI_FORMAT_FORCE_UINT` (0xFFFFFFFF), the
    /// read lands 360 GB past the table, and Genshin Impact dies before its
    /// first frame.
    ///
    /// The patch replaces the flags check and zero test (18 bytes at
    /// `0x1a4ea7`) with an unsigned range check sending 0 and anything from
    /// 191 up to the function's `E_INVALIDARG` path:
    ///
    ///     lea  eax, [rbp-1]    ; Format - 1, so 0 wraps to 0xFFFFFFFF
    ///     cmp  eax, 190
    ///     jae  0x1a4ef7        ; mov eax, E_INVALIDARG
    ///     nop  (8 bytes)
    ///
    /// The prologue and epilogue are untouched, so the unwind info holds;
    /// only a once-only log line for non-zero `Flags` is lost.
    static let checkMultisampleQualityLevels = Patch(
        name: "D3D11Device::CheckMultisampleQualityLevels1 format bound",
        build: "f5b56df1b8fe8b364dd9530651a3769c8aed948bd343be3b4510604d503e2bad",
        offset: 0x1A4EA7,
        original: [
            0x85, 0xC9, 0x74, 0x0A, 0x48, 0x83, 0x3D, 0xED, 0xC4,
            0x37, 0x00, 0xFF, 0x75, 0x52, 0x85, 0xED, 0x74, 0x3E,
        ],
        replacement: [
            0x8D, 0x45, 0xFF, 0x3D, 0xBE, 0x00, 0x00, 0x00, 0x73,
            0x46, 0x0F, 0x1F, 0x84, 0x00, 0x00, 0x00, 0x00, 0x00,
        ],
    )

    static let all = [checkMultisampleQualityLevels]

    /// The framework binary of an installed version.
    static func binary(of installed: D3DMetalInstaller.Installed) -> URL {
        installed.root.appendingPathComponent("lib/external/D3DMetal.framework/Versions/A/D3DMetal")
    }

    /// The framework version directory a bundle signature covers.
    static func framework(of installed: D3DMetalInstaller.Installed) -> URL {
        installed.root.appendingPathComponent("lib/external/D3DMetal.framework/Versions/A")
    }

    /// Where the untouched binary is kept, outside the framework.
    static func unpatchedCopy(of installed: D3DMetalInstaller.Installed) -> URL {
        installed.root.appendingPathComponent("D3DMetal.unpatched")
    }

    enum Outcome: Equatable, Sendable {
        /// No patch is for this build, or it already carries them.
        case unchanged
        case patched([String])
        case failed(String)
    }

    /// Patches `installed`'s binary in place when a known patch is for its
    /// build. The binary is hashed only when a patch's original bytes match.
    static func apply(
        to installed: D3DMetalInstaller.Installed, patches: [Patch] = all,
        sign: (URL) -> Bool = D3DMetalPatches.sign,
    ) -> Outcome {
        let url = binary(of: installed)
        guard var bytes = try? Data(contentsOf: url) else { return .unchanged }
        let due = patches.filter { $0.matches(bytes) }
        guard !due.isEmpty else { return .unchanged }
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let applicable = due.filter { $0.build == digest }
        guard !applicable.isEmpty else { return .unchanged }

        let manager = FileManager.default
        let keep = unpatchedCopy(of: installed)
        let staging = url.deletingLastPathComponent().appendingPathComponent("D3DMetal.patching")
        do {
            if !manager.fileExists(atPath: keep.path) {
                try manager.copyItem(at: url, to: keep)
            }
            for patch in applicable {
                bytes.replaceSubrange(
                    patch.offset ..< patch.offset + patch.replacement.count, with: patch.replacement,
                )
            }
            try? manager.removeItem(at: staging)
            try bytes.write(to: staging)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staging.path)
            _ = try manager.replaceItemAt(url, withItemAt: staging)
            // Never sign the binary alone: a quarantined bundle whose seal
            // does not match is reported as damaged when first loaded. The
            // quarantine flag goes too, since the file is no longer Apple's.
            let framework = framework(of: installed)
            guard sign(framework) else {
                try? manager.removeItem(at: url)
                let restored = (try? manager.copyItem(at: keep, to: url)) != nil
                return .failed("codesign refused the patched D3DMetal \(installed.version); "
                    + (restored ? "the original is back" : "the original could not be put back, so reinstall the toolkit"))
            }
            clearQuarantine(framework.deletingLastPathComponent().deletingLastPathComponent())
        } catch {
            try? manager.removeItem(at: staging)
            return .failed("could not patch D3DMetal \(installed.version): \(error.localizedDescription)")
        }
        return .patched(applicable.map(\.name))
    }

    /// Removes `com.apple.quarantine` from `url` and everything under it.
    static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Signs a framework version ad hoc: dyld maps a page only while it
    /// matches its signature.
    static func sign(_ url: URL) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", url.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}

nonisolated extension D3DMetalPatches.Patch {
    /// Whether `bytes` still holds what this patch replaces.
    func matches(_ bytes: Data) -> Bool {
        guard bytes.count >= offset + original.count else { return false }
        return bytes[offset ..< offset + original.count].elementsEqual(original)
    }
}
