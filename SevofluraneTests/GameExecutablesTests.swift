import Foundation
import Testing
@testable import Sevoflurane

/// The install-directory scan that names a game's exes before its first run.
struct GameExecutablesTests {
    @Test
    func `finds the game's exes shallowest first and leaves the tools out`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameExecutablesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = [
            "Game.exe", "UnityCrashHandler64.exe", "unins000.exe",
            "bin/Launcher.exe", "_CommonRedist/vcredist_x64.exe",
            "Binaries/Win64/Game-Win64-Shipping.exe",
            "Binaries/Win64/Deep/Too/Far.exe",
        ]
        try Self.make(files, under: root)
        let found = GameExecutables.executables(in: root)
        #expect(found == ["game.exe", "launcher.exe", "game-win64-shipping.exe"])
    }

    /// Unreal keeps the shipping binary three directories down, which is the
    /// deepest layout the scan reaches.
    @Test
    func `reaches Unreal's shipping executable`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameExecutablesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.make(
            ["b1/Binaries/Win64/b1-Win64-Shipping.exe", "Engine/Binaries/ThirdParty/Deep/Far.exe"],
            under: root,
        )
        #expect(GameExecutables.executables(in: root) == ["b1-win64-shipping.exe"])
    }

    /// Every game in a bottle that shares another bottle's files is a symlink
    /// to a directory, and the URL-based directory APIs read one as a file:
    /// scanning through the link is what makes the exes findable at all.
    @Test
    func `finds the exes of a game linked in from another bottle`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameExecutablesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let real = root.appendingPathComponent("source/Hollow Knight")
        try Self.make(["hollow_knight.exe", "bin/Tool.exe"], under: real)
        let common = root.appendingPathComponent("common")
        try FileManager.default.createDirectory(at: common, withIntermediateDirectories: true)
        let link = common.appendingPathComponent("Hollow Knight")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)

        #expect(GameExecutables.executables(in: link) == ["hollow_knight.exe", "tool.exe"])
    }

    /// A directory that is itself a link, inside a directory that is not.
    @Test
    func `follows a linked directory inside the install`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GameExecutablesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try Self.make(["elsewhere/Game.exe", "install/keep.txt"], under: root)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("install/bin"),
            withDestinationURL: root.appendingPathComponent("elsewhere"),
        )

        #expect(GameExecutables.executables(in: root.appendingPathComponent("install")) == ["game.exe"])
    }

    private static func make(_ files: [String], under root: URL) throws {
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data().write(to: url)
        }
    }

    @Test
    func `tool names are recognized`() {
        #expect(!GameExecutables.isGameLike("easyanticheat_setup.exe"))
        #expect(!GameExecutables.isGameLike("dxsetup.exe"))
        #expect(GameExecutables.isGameLike("siglusengine_steam.exe"))
        #expect(GameExecutables.isGameLike("planetarian.exe"))
    }
}
