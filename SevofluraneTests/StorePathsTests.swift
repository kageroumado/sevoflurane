import Foundation
import Testing
@testable import Sevoflurane

/// Store data never names a path Sevoflurane writes, starts or trashes
/// outside a managed install root.
struct StorePathsTests {
    /// A scratch install root, a game folder in it, and a folder beside it
    /// that no store game may reach.
    private struct Layout {
        let scratch: URL
        let root: URL
        let game: URL
        let outside: URL

        init() throws {
            scratch = FileManager.default.temporaryDirectory.appending(path: "store-paths-\(UUID().uuidString)")
            root = scratch.appending(path: "Games")
            game = root.appending(path: "Owl")
            outside = scratch.appending(path: "Documents")
            for folder in [game, outside] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: scratch)
        }
    }

    @Test
    func `a store name becomes one folder or the id`() {
        #expect(StorePaths.folderName("Unreal Gold", fallback: "1") == "Unreal Gold")
        #expect(StorePaths.folderName("../../x", fallback: "1207658924") == "1207658924")
        #expect(StorePaths.folderName("a/b", fallback: "Owl") == "Owl")
        #expect(StorePaths.folderName(".hidden", fallback: "Owl") == "Owl")
        #expect(StorePaths.folderName("..", fallback: "..") == nil)
        #expect(StorePaths.folderName("x\u{0}y", fallback: "") == nil)
        #expect(!StorePaths.isComponent(#"..\..\x"#))
    }

    @Test
    func `a game folder inside the root is placed, the root itself is not`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        #expect(StorePaths.root(containing: layout.game, roots: [layout.root], protected: []) != nil)
        #expect(StorePaths.root(containing: layout.root, roots: [layout.root], protected: []) == nil)
    }

    @Test
    func `a title of dot dot climbing out of the root is refused`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let climbing = layout.root.appending(path: "../Documents")
        #expect(StorePaths.root(containing: climbing, roots: [layout.root], protected: []) == nil)
        #expect(throws: StoreFailure.self) {
            try StorePaths.trash(climbing, roots: [layout.root], protected: [])
        }
        #expect(FileManager.default.fileExists(atPath: layout.outside.path))
    }

    @Test
    func `an absolute install path outside the root is refused`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        #expect(throws: StoreFailure.self) {
            try StorePaths.trash(layout.outside, roots: [layout.root], protected: [])
        }
        #expect(throws: StoreFailure.self) {
            try StorePaths.trash(URL(fileURLWithPath: "/"), roots: [layout.root], protected: [])
        }
        #expect(FileManager.default.fileExists(atPath: layout.outside.path))
    }

    @Test
    func `a symlink in the root that leads out of it is refused`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let link = layout.root.appending(path: "Escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: layout.outside)
        #expect(StorePaths.root(containing: link, roots: [layout.root], protected: []) == nil)
        #expect(throws: StoreFailure.self) {
            try StorePaths.trash(link, roots: [layout.root], protected: [])
        }
        #expect(FileManager.default.fileExists(atPath: layout.outside.path))
    }

    @Test
    func `a folder holding a protected one is never a root or a game`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let protected = [layout.outside]
        #expect(!StorePaths.acceptsRoot(layout.scratch, protected: protected))
        #expect(!StorePaths.acceptsRoot(URL(fileURLWithPath: "/"), protected: []))
        #expect(StorePaths.acceptsRoot(layout.root, protected: protected))
        #expect(StorePaths.root(containing: layout.outside, roots: [layout.scratch], protected: protected) == nil)
    }

    @Test
    func `a launch plan must start inside its game's folder`() throws {
        let layout = try Layout()
        defer { layout.remove() }
        let game = layout.game.path
        let inside = StoreLaunchPlan(folder: game, executable: game + "/Bin/Owl.exe", workingDirectory: game, arguments: [])
        #expect(StorePaths.accepts(inside, roots: [layout.root], protected: []))
        let escaping = StoreLaunchPlan(
            folder: game, executable: game + "/../../Documents/evil.exe", workingDirectory: game, arguments: [],
        )
        #expect(!StorePaths.accepts(escaping, roots: [layout.root], protected: []))
        let elsewhere = StoreLaunchPlan(
            folder: layout.outside.path, executable: layout.outside.path + "/a.exe",
            workingDirectory: layout.outside.path, arguments: [],
        )
        #expect(!StorePaths.accepts(elsewhere, roots: [layout.root], protected: []))
    }
}
