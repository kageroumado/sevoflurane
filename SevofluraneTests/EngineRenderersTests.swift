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

    func remove() {
        try? manager.removeItem(at: root)
    }

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

    /// The second architecture: the 32-bit tree and the `syswow64` a 32-bit
    /// process reads as its own `system32`.
    func addI386() throws {
        try manager.createDirectory(
            at: root.appendingPathComponent("wine/lib/wine/i386-windows"),
            withIntermediateDirectories: true,
        )
        try manager.createDirectory(
            at: bottle.appendingPathComponent("drive_c/windows/syswow64"),
            withIntermediateDirectories: true,
        )
    }

    /// The engine's own DXMT payload, both architectures, in the shape
    /// `package-engine.sh` lays down.
    func installDXMT(_ version: String) throws {
        for name in ["d3d11", "dxgi", "winemetal"] {
            try write("pe \(name) dxmt", to: "dxmt/\(name).dll")
            try write("pe32 \(name) dxmt", to: "dxmt/i386-windows/\(name).dll")
        }
        try write(
            """
            {"version": "test", "dxmt":
             "https://example.invalid/dxmt-v\(version)-builtin.tar.gz"}
            """,
            to: "engine-info.json",
        )
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

    /// The stale-loader bug: under D3DMetal the 32-bit pass has no payload,
    /// and bailing there left the previous renderer's `syswow64` files in
    /// place — a Sep 6 `winemetal.dll` under a tree that carries none.
    @Test
    func `an architecture with no payload still loses the last renderer's loader files`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        try engine.addI386()
        try engine.installDXMT("0.80")
        let toolkit = try engine.installToolkit("4.0 beta 2")

        EngineRenderers.stage(.dxmt, engine: engine.root, bottle: engine.bottle, toolkit: nil)
        #expect(engine.read("bottle/drive_c/windows/syswow64/winemetal.dll") != nil)

        EngineRenderers.stage(
            .d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: toolkit,
        )

        #expect(engine.read("bottle/drive_c/windows/syswow64/winemetal.dll") == nil)
        #expect(engine.read("wine/lib/wine/i386-windows/winemetal.dll") == nil)
        // The 64-bit half is D3DMetal's, and its loader files are still there.
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 4.0 beta 2")
        #expect(engine.read("bottle/drive_c/windows/system32/dxgi.dll") != nil)
    }

    /// `auto` and `wined3d` stage nothing at all, which is exactly when the
    /// prefix is left holding whatever the last renderer put there.
    @Test
    func `wined3d clears the prefix of the last renderer's files`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        try engine.addI386()
        try engine.installDXMT("0.80")

        EngineRenderers.stage(.dxmt, engine: engine.root, bottle: engine.bottle, toolkit: nil)
        EngineRenderers.stage(.wined3d, engine: engine.root, bottle: engine.bottle, toolkit: nil)

        // winemetal is DXMT's alone: the tree lost it, so the prefix must too.
        #expect(engine.read("bottle/drive_c/windows/system32/winemetal.dll") == nil)
        #expect(engine.read("bottle/drive_c/windows/syswow64/winemetal.dll") == nil)
        // dxgi is Wine's own again, and the prefix still has a file for it —
        // without one, a game importing dxgi dies at load.
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "stock dxgi")
        #expect(engine.read("bottle/drive_c/windows/system32/dxgi.dll") != nil)
    }

    @Test
    func `the bridge a launch names is the tree's copy`() {
        let engine = URL(fileURLWithPath: "/engines/dormison-r2")
        #expect(
            D3DMetalInstaller.bridgeLibrary(inEngine: engine).path
                == "/engines/dormison-r2/wine/lib/external/libd3dshared.dylib",
        )
    }
}

/// The ground-truth probe: what a game actually loads, both halves, matched
/// by content — the thing that answers "is the version I picked what runs?"
struct D3DMetalPlacementTests {
    @Test
    func `a version switch leaves no trace of the old one, both halves`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let three = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")

        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: three)
        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: four)

        // What a game loads is both halves 4.0's: the canonical tree copy Wine
        // resolves a builtin to, and the macOS bridge beside it. (system32
        // holds a marker file only — its bytes are deliberately not the
        // renderer, so they are not asserted here.)
        let placement = D3DMetalInstaller.placement(inEngine: engine.root)
        #expect(placement == D3DMetalInstaller.Placement(macOS: "4.0 beta 2", windows: "4.0 beta 2"))
        #expect(placement.halvesAgree)
        #expect(engine.read("wine/lib/external/libd3dshared.dylib") == "bridge 4.0 beta 2")
        #expect(engine.read("wine/lib/wine/x86_64-windows/d3d12.dll") == "pe d3d12 4.0 beta 2")
        #expect(engine.read("wine/lib/wine/x86_64-windows/dxgi.dll") == "pe dxgi 4.0 beta 2")
        _ = (three, four)
    }

    /// The exact failure the record-only picker prevents: 4.0's macOS half
    /// over 3.0's Windows half. The probe must call it out rather than pass.
    @Test
    func `the probe catches a crossed tree`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        let three = try engine.installToolkit("3.0")
        let four = try engine.installToolkit("4.0 beta 2")

        // Windows half staged as 3.0, then only the macOS half swapped to 4.0
        // — what the old eager picker did on a live switch.
        EngineRenderers.stage(.d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: three)
        try D3DMetalInstaller.place(four, inEngine: engine.root)

        let placement = D3DMetalInstaller.placement(inEngine: engine.root)
        #expect(placement.macOS == "4.0 beta 2")
        #expect(placement.windows == "3.0")
        #expect(!placement.halvesAgree)
    }
}

/// What the engine reads at every process start to say which renderer
/// answered: `<engine>/renderer-hashes`, `key=value` lines with `#` comments.
struct EngineRendererProvenanceTests {
    private func entries(_ engine: FakeEngine) -> [String: String] {
        let text = engine.read(EngineRenderers.provenanceFile) ?? ""
        var found: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2 else { continue }
            found[String(parts[0])] = String(parts[1])
        }
        return found
    }

    @Test
    func `staging records the renderer, its version and a hash per DLL`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        try engine.addI386()
        try engine.installDXMT("0.80")

        EngineRenderers.stage(.dxmt, engine: engine.root, bottle: engine.bottle, toolkit: nil)

        let entries = entries(engine)
        #expect(entries["renderer"] == "dxmt")
        #expect(entries["toolkit"] == "0.80")
        // The sha256 of the canonical tree copy, lower-case hex.
        let d3d11 = try FileDigest.sha256(
            of: engine.root.appendingPathComponent("wine/lib/wine/x86_64-windows/d3d11.dll"),
        )
        #expect(entries["d3d11"] == d3d11)
        #expect(entries["dxgi"]?.count == 64)
        #expect(entries["dxgi"] == entries["dxgi"]?.lowercased())
    }

    @Test
    func `the record is rewritten whole at the next staging`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        try engine.installDXMT("0.80")
        let toolkit = try engine.installToolkit("4.0 beta 2")

        EngineRenderers.stage(.dxmt, engine: engine.root, bottle: engine.bottle, toolkit: nil)
        EngineRenderers.stage(
            .d3dmetal, engine: engine.root, bottle: engine.bottle, toolkit: toolkit,
        )

        let entries = entries(engine)
        #expect(entries["renderer"] == "d3dmetal")
        #expect(entries["toolkit"] == "4.0 beta 2")
        #expect(entries["d3d12"]?.count == 64)
        // DXMT's own DLL is gone from the tree, so its hash is gone too.
        #expect(entries["winemetal"] == nil)
    }

    /// A renderer that stages nothing still says so, because the engine
    /// prints `unknown` for a file it cannot find and "wined3d" is not
    /// "unknown".
    @Test
    func `wined3d is recorded as itself`() throws {
        let engine = try FakeEngine()
        defer { engine.remove() }
        try engine.installDXMT("0.80")

        EngineRenderers.stage(.wined3d, engine: engine.root, bottle: engine.bottle, toolkit: nil)

        let entries = entries(engine)
        #expect(entries["renderer"] == "wined3d")
        #expect(entries["toolkit"] == nil)
        #expect(entries["d3d11"] == nil)
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

/// Installing a toolkit from Apple's image, and which version a game then gets.
struct D3DMetalInstallTests {
    private let manager = FileManager.default

    /// An unpacked toolkit named the way Apple's volume is, carrying the
    /// framework the installer identifies it by.
    private func toolkit(_ version: String, in dir: URL) throws -> URL {
        let volume = dir.appendingPathComponent("Evaluation environment for Windows games \(version)")
        try manager.createDirectory(
            at: volume.appendingPathComponent("redist/lib/external/D3DMetal.framework"),
            withIntermediateDirectories: true,
        )
        return volume
    }

    @Test
    func `the newest installed toolkit is active whichever download finished last`() async throws {
        let dir = manager.temporaryDirectory.appendingPathComponent("d3dmetal-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: dir) }
        let engine = dir.appendingPathComponent("engine")
        let suite = "d3dmetal-tests-\(UUID().uuidString)"
        let preferences = try #require(UserDefaults(suiteName: suite))
        defer { preferences.removePersistentDomain(forName: suite) }

        _ = try await D3DMetalInstaller.install(from: toolkit("4.0 beta 2", in: dir), intoEngine: engine)
        _ = try await D3DMetalInstaller.install(from: toolkit("3.0", in: dir), intoEngine: engine)
        #expect(D3DMetalInstaller.active(inEngine: engine, preferences: preferences)?.version == "4.0 beta 2")
    }
}
