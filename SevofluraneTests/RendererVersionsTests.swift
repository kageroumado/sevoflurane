import Foundation
import Testing
@testable import Sevoflurane

/// The renderer-version store: names, layouts, and what counts as newer.
struct RendererVersionsTests {
    @Test
    func `release names reduce to the version people say`() {
        #expect(RendererVersions.Component.dxmt.version(from: "dxmt-v0.80-builtin.tar.gz") == "0.80")
        #expect(RendererVersions.Component.dxmt.version(from: "v0.74") == "0.74")
        #expect(RendererVersions.Component.dxvk.version(from: "dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz")
            == "1.10.3-20230507-repack")
        #expect(RendererVersions.Component.dxvk.version(from: "v1.10.3-20230507-repack") == "1.10.3-20230507-repack")
    }

    @Test
    func `only builtin payloads are release assets`() {
        #expect(RendererVersions.Component.dxmt.isPayloadAsset("dxmt-v0.80-builtin.tar.gz"))
        #expect(!RendererVersions.Component.dxvk.isPayloadAsset("dxvk-macOS-async-v1.10.3-20230507.tar.gz"))
        #expect(RendererVersions.Component.dxvk.isPayloadAsset("dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz"))
    }

    @Test
    func `the two halves are found by dxgi.dll, the 32-bit one by its folder name`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RendererVersionsTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        for file in ["pkg/x86_64-windows/dxgi.dll", "pkg/x86_64-windows/d3d11.dll", "pkg/i386-windows/dxgi.dll"] {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        let halves = try #require(RendererVersions.locateHalves(under: root))
        #expect(halves.x86_64.lastPathComponent == "x86_64-windows")
        #expect(halves.i386?.lastPathComponent == "i386-windows")
        #expect(RendererVersions.locateHalves(under: root.appendingPathComponent("nowhere")) == nil)
    }

    @Test
    func `newer means newer than the default and everything installed`() throws {
        let url = try #require(URL(string: "https://example.invalid/x"))
        func release(_ version: String) -> RendererVersions.Release {
            .init(component: .dxmt, version: version, url: url, tested: false, sha256: nil)
        }
        let releases = [release("0.81"), release("0.80"), release("0.74")]
        #expect(RendererVersions.newerRelease(than: [], default: "0.80", among: releases)?.version == "0.81")
        #expect(RendererVersions.newerRelease(than: ["0.81"], default: "0.80", among: releases) == nil)
        #expect(RendererVersions.newerRelease(than: ["0.74"], default: nil, among: releases)?.version == "0.81")
    }
}
