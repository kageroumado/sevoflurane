import Foundation
import Testing
@testable import Sevoflurane

/// A managed engine built from marker files: two D3DMetal toolkits, a Wine
/// tree holding one of them, and a bottle with an empty system32.
private struct FakeEngine {
    let root: URL
    let bottle: URL
    let manager = FileManager.default

    init() throws {
        root = manager.temporaryDirectory
            .appendingPathComponent("sevo-engine-\(UUID().uuidString)")
        bottle = root.appendingPathComponent("bottle")
        try manager.createDirectory(
            at: root.appendingPathComponent("wine/lib/wine/x86_64-windows"),
            withIntermediateDirectories: true,
        )
        try manager.createDirectory(
            at: root.appendingPathComponent("wine/lib/wine/x86_64-unix"),
            withIntermediateDirectories: true,
        )
        try manager.createDirectory(
            at: bottle.appendingPathComponent("drive_c/windows/system32"),
            withIntermediateDirectories: true,
        )
        try write("stock dxgi", to: "wine/lib/wine/x86_64-windows/dxgi.dll")
    }

    func remove() { try? manager.removeItem(at: root) }

    /// Lays down a toolkit the way the installer does: Apple's `lib/` shape,
    /// stubs as symlinks into `external`.
    func installToolkit(_ version: String) throws -> D3DMetalInstaller.Installed {
        let toolkit = root.appendingPathComponent("d3dmetal/\(version)")
        let lib = "d3dmetal/\(version)/lib"
        try write("bridge \(version)", to: "\(lib)/external/libd3dshared.dylib")
        try write("framework \(version)", to: "\(lib)/external/D3DMetal.framework/Versions/A/D3DMetal")
        try write("pe dxgi \(version)", to: "\(lib)/wine/x86_64-windows/dxgi.dll")
        try write("pe d3d12 \(version)", to: "\(lib)/wine/x86_64-windows/d3d12.dll")
        let unix = toolkit.appendingPathComponent("lib/wine/x86_64-unix")
        try manager.createDirectory(at: unix, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            atPath: unix.appendingPathComponent("d3d12.so").path,
            withDestinationPath: "../../external/libd3dshared.dylib",
        )
        return D3DMetalInstaller.Installed(version: version, root: toolkit)
    }

    func write(_ text: String, to relative: String) throws {
        let url = root.appendingPathComponent(relative)
        try manager.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try Data(text.utf8).write(to: url)
    }

    func read(_ relative: String) -> String? {
        (try? Data(contentsOf: root.appendingPathComponent(relative)))
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

struct EngineRenderersTests {
    @Test
    func `staging puts the picked toolkit's macOS side into the Wine tree`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let three = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")
        try D3DMetalInstaller.place(three, inEngine: engine.root)
        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 3.0")

        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)

        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 4.0 beta 2")
        #expect(
            engine.read("wine/lib/external/D3DMetal.framework/Versions/A/D3DMetal")
                == "framework 4.0 beta 2",
        )
        let stub = engine.root.appendingPathComponent("wine/lib/wine/x86_64-unix/d3d12.so")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: stub.path)
                == "../../external/libd3dshared.dylib",
        )
        #expect(D3DMetalInstaller.isPlaced(four, inEngine: engine.root))
        #expect(!D3DMetalInstaller.isPlaced(three, inEngine: engine.root))
    }

    @Test
    func `a tree swapped by hand is put back at the next staging`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let four = try engine.installToolkit("4.0 beta 2")
        try D3DMetalInstaller.place(four, inEngine: engine.root)
        try engine.write("bridge from somewhere else", to: "wine/lib/external/libd3dshared.dylib")
        #expect(!D3DMetalInstaller.isPlaced(four, inEngine: engine.root))

        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)

        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 4.0 beta 2")
    }

    /// The two halves are one release: a PE DLL carries a function index into
    /// the unix-side dylib, and the releases do not number those alike.
    @Test
    func `the Windows side is the picked toolkit's too`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        _ = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")

        let staged = EngineRenderers.stage(
            .d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four,
        )

        #expect(Set(staged) == ["dxgi.dll", "d3d12.dll"])
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 4.0 beta 2")
        #expect(engine.read("wine/lib/wine/x86_64-windows-original/dxgi.dll") == "stock dxgi")
        #expect(engine.read("bottle/drive_c/windows/system32/dxgi.dll") == "pe dxgi 4.0 beta 2")
        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 4.0 beta 2")
    }

    @Test
    func `picking 3.0 stages 3.0 on both halves`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let three = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")
        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)

        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: three)

        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 3.0")
        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 3.0")
    }

    @Test
    func `the bridge a launch names is the tree's copy`() {
        let engine = URL(fileURLWithPath: "/engines/sevo-r1d")
        #expect(
            D3DMetalInstaller.bridgeLibrary(inEngine: engine).path
                == "/engines/sevo-r1d/wine/lib/external/libd3dshared.dylib",
        )
    }
}

struct EngineRendererStrayTests {
    /// A payload DLL that reached the tree before its name was ever staged
    /// was kept as Wine's own, and restored over every later version.
    @Test
    func `a renderer's own DLL is never kept as Wine's`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let three = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")
        // 3.0 ships a DLL 4.0b2 does not, and an older build recorded it as stock.
        try engine.write("pe atidxx64 3.0", to: "d3dmetal/3.0/lib/wine/x86_64-windows/atidxx64.dll")
        try engine.write("pe atidxx64 3.0", to: "wine/lib/wine/x86_64-windows/atidxx64.dll")
        try engine.write("pe atidxx64 3.0", to: "wine/lib/wine/x86_64-windows-original/atidxx64.dll")
        try engine.write("pe atidxx64 3.0", to: "bottle/drive_c/windows/system32/atidxx64.dll")

        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)

        #expect(engine.read("wine/lib/wine/x86_64-windows/atidxx64.dll") == nil)
        #expect(engine.read("wine/lib/wine/x86_64-windows-original/atidxx64.dll") == nil)
        #expect(engine.read("bottle/drive_c/windows/system32/atidxx64.dll") == nil)
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 4.0 beta 2")
        _ = three
    }

    /// Wine's own builtin still comes back when the renderer stops supplying
    /// a name it had displaced.
    @Test
    func `a displaced Wine builtin is still restored`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let four = try engine.installToolkit("4.0 beta 2")
        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 4.0 beta 2")

        EngineRenderers.stage(.wined3d, engine: engine.root, bottle: engine.bottle, toolkit: four)

        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "stock dxgi")
    }
}
