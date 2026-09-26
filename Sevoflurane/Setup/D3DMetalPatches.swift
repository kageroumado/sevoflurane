import CryptoKit
import Foundation

/// Byte-for-byte corrections to a D3DMetal build that crashes a game, applied
/// to the shared store's copy so the Wine tree, which ``D3DMetalInstaller``
/// keeps equal to the store, gets it at the next staging.
///
/// Each patch is pinned to one build by the SHA-256 of the untouched binary
/// and to the exact bytes it replaces, and does nothing to anything else: a
/// release that fixes the bug has another hash and is left alone. The
/// untouched binary is kept beside the version as `D3DMetal.unpatched`, and
/// the framework is signed ad hoc, since a changed page no longer matches
/// Apple's signature. Installing the toolkit again brings Apple's back.
nonisolated enum D3DMetalPatches {
    struct Patch: Sendable {
        /// What the log names it by.
        let name: String
        /// The SHA-256 of the build it applies to, before any patch.
        let build: String
        /// The file offset of the first replaced byte. D3DMetal is a thin
        /// x86_64 image whose `__TEXT` starts at file offset 0, so this is
        /// also the address `otool` prints.
        let offset: Int
        let original: [UInt8]
        let replacement: [UInt8]
    }

    /// D3DMetal 4.0 beta 2 (Game Porting Toolkit 4.0 beta 2):
    /// `D3D11Device::CheckMultisampleQualityLevels1`, which the plain
    /// `CheckMultisampleQualityLevels` tail-calls, rejects only format 0 and
    /// then reads `_dxgi_info[Format]`, 0x58 bytes an entry, with no upper
    /// bound. The table has room for 191 entries. Unity asks with
    /// `DXGI_FORMAT_FORCE_UINT` (0xFFFFFFFF) while it sets its device up, the
    /// read lands 360 GB past the table, and the game dies before its first
    /// frame: Genshin Impact, every launch. 3.0 answered `E_NOTIMPL` without
    /// reading anything.
    ///
    /// The patch replaces the flags check and the zero test, 18 bytes at
    /// `0x1a4ea7`, with one unsigned range check that sends 0 and anything
    /// from 191 up to the function's own `E_INVALIDARG` path:
    ///
    ///     lea  eax, [rbp-1]    ; Format - 1, so 0 wraps to 0xFFFFFFFF
    ///     cmp  eax, 190
    ///     jae  0x1a4ef7        ; mov eax, E_INVALIDARG
    ///     nop  (8 bytes)
    ///
    /// The prologue and epilogue are untouched, so the unwind info still
    /// describes the function. What goes is a once-only log line for a
    /// non-zero `Flags`, which changed nothing else.
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

    /// The framework version directory the binary belongs to, which is
    /// what a bundle signature covers.
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

    /// Patches `installed`'s framework binary in place if a known patch is
    /// for its build. Cheap when there is nothing to do: one read of the
    /// binary, only once the bytes at a patch's offset match its original.
    ///
    /// `patches` and `sign` are the shipping list and the ad hoc signature
    /// outside tests.
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
            // The whole framework, not the binary alone: its seal lists the
            // binary's hash, and a quarantined bundle whose seal does not
            // match is what macOS calls damaged, in a dialog, the first time
            // a process loads it (2026-09-26, the patched binary signed on
            // its own). The quarantine flag goes too: it came with Apple's
            // download, and what it vouches for is no longer this file.
            let framework = framework(of: installed)
            guard sign(framework) else {
                try? manager.removeItem(at: url)
                try? manager.copyItem(at: keep, to: url)
                return .failed("codesign refused the patched D3DMetal \(installed.version); the original is back")
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

    /// An ad hoc signature for a framework version: dyld maps a page only
    /// while it matches the signature it was signed with, and the patched
    /// page no longer matches Apple's.
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

    /// Whether `bytes` already carries this patch.
    func isApplied(in bytes: Data) -> Bool {
        guard bytes.count >= offset + replacement.count else { return false }
        return bytes[offset ..< offset + replacement.count].elementsEqual(replacement)
    }
}
