import Foundation
import Testing
@testable import Sevoflurane

/// The line the log keeps for each setting that changes: a value nobody
/// remembers choosing is explained by it or by nothing.
struct ConfigChangeTrailTests {
    @Test
    func `a changed setting reads as what it was and what it is`() {
        var before = ConfigValues.empty
        before.upscaler = "anime4k-c"
        var after = before
        after.upscaler = "lanczos"
        #expect(GameConfig.changes(from: before, to: after) == ["upscaler anime4k-c → lanczos"])
    }

    @Test
    func `a level that stops setting a value goes back to inherit, and a switch reads on or off`() {
        var before = ConfigValues.empty
        before.fps = true
        #expect(GameConfig.changes(from: .empty, to: before) == ["fps inherit → on"])
        #expect(GameConfig.changes(from: before, to: .empty) == ["fps on → inherit"])
    }

    @Test
    func `what a level records about a game is no setting`() {
        var after = ConfigValues.empty
        after.exes = ["game.exe"]
        after.name = "A Game"
        #expect(GameConfig.changes(from: .empty, to: after).isEmpty)
    }
}
