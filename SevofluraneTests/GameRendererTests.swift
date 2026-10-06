import Foundation
import Testing
@testable import Sevoflurane

/// A renderer given to one game: which layers can travel in an env file, the
/// prepend directory that carries one, and the lines a game's file gets.
struct GameRendererTests {
    /// A fake engine tree with the payload directories a renderer stages from.
    private struct Tree {
        let root: URL

        init(payloads: [String: [String]]) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("sevo-renderer-\(UUID().uuidString)")
            for (payload, dlls) in payloads {
                let directory = root.appendingPathComponent(payload)
                try FileManager.default.createDirectory(
                    at: directory, withIntermediateDirectories: true,
                )
                for dll in dlls {
                    try Data().write(to: directory.appendingPathComponent(dll))
                }
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    @Test
    func `the layers with a builtin-flavored payload travel in an env file`() {
        #expect(EngineRenderers.supportsPerGame(.dxmt))
        #expect(EngineRenderers.supportsPerGame(.dxvk))
        #expect(!EngineRenderers.supportsPerGame(.wined3d))
        #expect(!EngineRenderers.supportsPerGame(.auto))
        // D3DMetal rides the same switch, which the GPTk prepend probe flips.
        #expect(EngineRenderers.supportsPerGame(.d3dmetal)
            == EngineRenderers.gptkLoadsFromPrependPath)
    }

    @Test
    func `the prepend directory links the payload under the machine name`() throws {
        let tree = try Tree(payloads: [
            "dxmt": ["d3d11.dll", "dxgi.dll"],
            "dxmt/i386-windows": ["d3d11.dll"],
        ])
        defer { tree.remove() }
        let directory = try #require(EngineRenderers.prependDirectory(
            for: .dxmt, engine: tree.root, toolkit: nil,
        ))
        #expect(directory.lastPathComponent == "dxmt")
        let modules = directory.appendingPathComponent("x86_64-windows")
        #expect(FileManager.default.fileExists(
            atPath: modules.appendingPathComponent("dxgi.dll").path,
        ))
        #expect(FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("i386-windows/d3d11.dll").path,
        ))
        // DXMT's winemetal.dll finds its unix half beside it, which is the
        // engine's own: an engine before b2 looks nowhere else.
        #expect(try FileManager.default.destinationOfSymbolicLink(
            atPath: directory.appendingPathComponent("x86_64-unix").path,
        ) == tree.root.appendingPathComponent("wine/lib/wine/x86_64-unix").standardizedFileURL.path)
        // Twice is the same answer: the materializer runs at every store
        // change and at every client start.
        #expect(EngineRenderers.prependDirectory(
            for: .dxmt, engine: tree.root, toolkit: nil,
        )?.path == directory.path)
    }

    @Test
    func `a renderer this engine has no payload for gets no directory`() throws {
        let tree = try Tree(payloads: ["dxmt": ["d3d11.dll"]])
        defer { tree.remove() }
        #expect(EngineRenderers.prependDirectory(
            for: .dxvk, engine: tree.root, toolkit: nil,
        ) == nil)
        #expect(EngineRenderers.prependDirectory(
            for: .wined3d, engine: tree.root, toolkit: nil,
        ) == nil)
    }

    @Test
    func `every DLL the directory supplies is forced builtin, in one order`() throws {
        let tree = try Tree(payloads: ["dxmt": ["dxgi.dll", "d3d11.dll", "d3d10core.dll"]])
        defer { tree.remove() }
        let directory = try #require(EngineRenderers.prependDirectory(
            for: .dxmt, engine: tree.root, toolkit: nil,
        ))
        #expect(EngineRenderers.perGameDLLOverrides(in: directory)
            == "d3d10core,d3d11,dxgi=b")
    }

    @Test
    func `the game's lines name the directory and the overrides`() throws {
        let tree = try Tree(payloads: ["dxmt": ["d3d11.dll", "dxgi.dll"]])
        defer { tree.remove() }
        var values = ConfigValues.empty
        values.renderer = .dxmt
        let lines = ConfigMaterializer.gameLines(1_962_700, values, engine: tree.root)
        let directory = tree.root.appendingPathComponent("renderers/dxmt").path
        #expect(lines.contains("WINEDLLPATH_PREPEND=\(directory)"))
        #expect(lines.contains("WINEDLLOVERRIDES=d3d11,dxgi=b"))
    }

    @Test
    func `a renderer no prepend path can carry leaves the game's lines alone`() throws {
        let tree = try Tree(payloads: ["dxmt": ["d3d11.dll"]])
        defer { tree.remove() }
        var values = ConfigValues.empty
        values.renderer = .wined3d
        let lines = ConfigMaterializer.gameLines(1_962_700, values, engine: tree.root)
        #expect(!lines.contains { $0.hasPrefix("WINEDLLPATH_PREPEND=") })
    }

    @Test
    func `a renderer is a setting, and survives the round trip`() throws {
        var values = ConfigValues.empty
        #expect(!values.hasSettings)
        values.renderer = .dxvk
        #expect(values.hasSettings)
        let back = try JSONDecoder().decode(
            ConfigValues.self, from: JSONEncoder().encode(values),
        )
        #expect(back.renderer == .dxvk)
    }
}
