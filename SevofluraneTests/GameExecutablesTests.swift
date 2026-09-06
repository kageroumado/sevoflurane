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
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try Data().write(to: url)
        }
        let found = GameExecutables.executables(in: root)
        #expect(found == ["game.exe", "launcher.exe", "game-win64-shipping.exe"])
    }

    @Test
    func `tool names are recognized`() {
        #expect(!GameExecutables.isGameLike("easyanticheat_setup.exe"))
        #expect(!GameExecutables.isGameLike("dxsetup.exe"))
        #expect(GameExecutables.isGameLike("siglusengine_steam.exe"))
        #expect(GameExecutables.isGameLike("planetarian.exe"))
    }
}
