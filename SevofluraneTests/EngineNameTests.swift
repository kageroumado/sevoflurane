import Foundation
import Testing
@testable import Sevoflurane

/// A managed engine is a folder of `Engines`, whoever names it: `sevo engine
/// use`, the MCP tool, the control port and the stored choice all pass through
/// `Engine.named` and `existsOnDisk`, so a name that climbs out of the folder
/// selects nothing.
struct EngineNameTests {
    @Test
    func `a managed engine is named by one folder name`() throws {
        for name in ["../x", "a/b", "/abs", ".", "..", "", "dormison\u{0}b1", "dormison-b1/"] {
            #expect(!Engine.isManagedName(name), "\(name)")
            #expect(throws: Engine.NameRefusal(name: name)) { try Engine.named(name) }
        }
        #expect(Engine.isManagedName("dormison-b1"))
        #expect(try Engine.named("dormison-b1") == .managed(version: "dormison-b1"))
        #expect(try Engine.named("crossover") == .crossover)
        #expect(try Engine.named("crossover-preview") == .crossoverPreview)
    }

    @Test
    func `a folder counts only when it resolves inside the engines folder`() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("sevo-engine-names-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: root) }
        let engines = root.appendingPathComponent("Engines")
        let outside = root.appendingPathComponent("Outside")
        try manager.createDirectory(at: engines.appendingPathComponent("dormison-b1"), withIntermediateDirectories: true)
        try manager.createDirectory(at: outside, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: engines.appendingPathComponent("escape"), withDestinationURL: outside)
        try manager.createSymbolicLink(
            at: engines.appendingPathComponent("alias"),
            withDestinationURL: engines.appendingPathComponent("dormison-b1"),
        )

        let installed = try #require(Engine.managedDirectory("dormison-b1", in: engines))
        #expect(installed.lastPathComponent == "dormison-b1")
        #expect(Engine.managedDirectory("alias", in: engines) == installed)
        #expect(Engine.managedDirectory("escape", in: engines) == nil)
        #expect(Engine.managedDirectory("../Outside", in: engines) == nil)
        #expect(Engine.managedDirectory(".", in: engines) == nil)
        #expect(Engine.managedDirectory("..", in: engines) == nil)
        #expect(Engine.managedDirectory("", in: engines) == nil)
        #expect(Engine.managedDirectory("missing", in: engines) == nil)
    }

    @Test
    func `an engine named outside the engines folder is not installed`() throws {
        let manager = FileManager.default
        let escape = "Escape-\(UUID().uuidString)"
        let target = Engine.managedRoot.deletingLastPathComponent().appendingPathComponent(escape)
        try manager.createDirectory(at: Engine.managedRoot, withIntermediateDirectories: true)
        try manager.createDirectory(at: target.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: target) }
        #expect(!Engine.managed(version: "../\(escape)").existsOnDisk)
        #expect(Engine.booted(fromRoot: Engine.managedRoot.path + "/..") == nil)
    }
}
