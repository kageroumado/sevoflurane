import Foundation
import Testing
@testable import Sevoflurane

/// Which game's records claim an executable.
struct GameAttributionTests {
    private static let games: [Int: ConfigValues] = {
        var uninstalled = ConfigValues.empty
        uninstalled.exes = ["game.exe"]
        var installed = ConfigValues.empty
        installed.exes = ["game.exe", "launcher.exe"]
        var adopted = ConfigValues.empty
        adopted.exes = ["tool.exe"]
        return [603_750: uninstalled, 1_234_567: installed, 2_000_000_001: adopted]
    }()

    @Test
    func `an uninstalled Steam game claims nothing, an adopted program needs no manifest`() {
        let claimants = GameConfig.claimants(in: Self.games, installed: [1_234_567])
        #expect(Set(claimants.keys) == [1_234_567, 2_000_000_001])
        #expect(GameConfig.app(claiming: "Game.exe", in: claimants) == 1_234_567)
        #expect(GameConfig.app(claiming: "tool.exe", in: claimants) == 2_000_000_001)
    }

    @Test
    func `two claimants of one exe answer the lower app id, and a Windows tool is nobody's`() {
        #expect(GameConfig.app(claiming: "game.exe", in: Self.games) == 603_750)
        #expect(GameConfig.app(claiming: "launcher.exe", in: Self.games) == 1_234_567)
        #expect(GameConfig.app(claiming: "regsvr32.exe", in: Self.games) == nil)
        #expect(GameConfig.app(claiming: "unknown.exe", in: Self.games) == nil)
    }
}
