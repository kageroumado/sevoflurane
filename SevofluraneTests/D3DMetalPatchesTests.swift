import CryptoKit
import Foundation
import Testing
@testable import Sevoflurane

/// The byte patches for D3DMetal builds that crash games: pinned to a build,
/// applied once, and the original kept.
struct D3DMetalPatchesTests {
    /// A toolkit whose framework binary is `bytes`, in a directory of its own.
    private static func toolkit(_ bytes: [UInt8]) throws -> D3DMetalInstaller.Installed {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("d3dmetal-patches-\(UUID().uuidString)")
        let installed = D3DMetalInstaller.Installed(version: "4.0 beta 2", root: root)
        let binary = D3DMetalPatches.binary(of: installed)
        try FileManager.default.createDirectory(
            at: binary.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(bytes).write(to: binary)
        return installed
    }

    private static func digest(_ bytes: [UInt8]) -> String {
        SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    /// 64 bytes with `original` at offset 16, and a patch pinned to them.
    private static func fixture() -> (bytes: [UInt8], patch: D3DMetalPatches.Patch) {
        var bytes = [UInt8](repeating: 0x90, count: 64)
        bytes.replaceSubrange(16 ..< 20, with: [0x85, 0xED, 0x74, 0x3E])
        let patch = D3DMetalPatches.Patch(
            name: "fixture", build: digest(bytes), offset: 16,
            original: [0x85, 0xED, 0x74, 0x3E], replacement: [0x8D, 0x45, 0xFF, 0x90],
        )
        return (bytes, patch)
    }

    @Test
    func `the shipping patch swaps like for like and jumps to the E_INVALIDARG path`() {
        let patch = D3DMetalPatches.checkMultisampleQualityLevels
        #expect(patch.original.count == patch.replacement.count)
        // `jae rel8` is the ninth byte; its target is counted from the byte
        // after it and must be `mov eax, 0x80070057` at 0x1a4ef7.
        #expect(patch.replacement[8] == 0x73)
        #expect(patch.offset + 10 + Int(patch.replacement[9]) == 0x1A4EF7)
        // cmp eax, 190: formats 1 through 190 pass, 0 and 191 up do not.
        #expect(Array(patch.replacement[3 ..< 8]) == [0x3D, 0xBE, 0x00, 0x00, 0x00])
    }

    @Test
    func `a build with the pinned hash is patched, signed, and its original kept`() throws {
        let (bytes, patch) = Self.fixture()
        let installed = try Self.toolkit(bytes)
        var signed: [URL] = []
        let outcome = D3DMetalPatches.apply(to: installed, patches: [patch]) {
            signed.append($0)
            return true
        }
        #expect(outcome == .patched(["fixture"]))
        #expect(signed.count == 1)
        let now = try Data(contentsOf: D3DMetalPatches.binary(of: installed))
        #expect(Array(now[16 ..< 20]) == patch.replacement)
        #expect(try Data(contentsOf: D3DMetalPatches.unpatchedCopy(of: installed)) == Data(bytes))
    }

    @Test
    func `a patched build is left alone the next time`() throws {
        let (bytes, patch) = Self.fixture()
        let installed = try Self.toolkit(bytes)
        _ = D3DMetalPatches.apply(to: installed, patches: [patch]) { _ in true }
        let again = D3DMetalPatches.apply(to: installed, patches: [patch]) { _ in
            Issue.record("signed a build that needed nothing")
            return true
        }
        #expect(again == .unchanged)
    }

    @Test
    func `another build with the same bytes at the offset is not touched`() throws {
        let fixture = Self.fixture()
        let patch = fixture.patch
        var bytes = fixture.bytes
        bytes[63] = 0x00
        let installed = try Self.toolkit(bytes)
        #expect(D3DMetalPatches.apply(to: installed, patches: [patch]) { _ in true } == .unchanged)
        #expect(try Data(contentsOf: D3DMetalPatches.binary(of: installed)) == Data(bytes))
        #expect(patch.matches(Data(bytes)))
    }

    @Test
    func `a signature that fails leaves the original in place`() throws {
        let (bytes, patch) = Self.fixture()
        let installed = try Self.toolkit(bytes)
        let outcome = D3DMetalPatches.apply(to: installed, patches: [patch]) { _ in false }
        guard case .failed = outcome else {
            Issue.record("expected a failure, got \(outcome)")
            return
        }
        #expect(try Data(contentsOf: D3DMetalPatches.binary(of: installed)) == Data(bytes))
    }
}
