import Foundation
import Testing
@testable import Sevoflurane

/// What a changed setting costs to reach a game — the badge Settings shows and
/// the sentence `sevo` prints.
struct SettingReachTests {
    @Test
    func `each cost says what it is, in one line`() {
        for reach in [SettingReach.nextLaunch, .clientRestart, .recorded] {
            #expect(!reach.label.isEmpty)
            #expect(!reach.detail.isEmpty)
        }
        #expect(SettingReach.clientRestart.detail.contains("30 s"))
    }

    @Test
    func `the registry reaches a game at its next launch whatever the engine is`() {
        // Wine opens the per-program key at process start and the registry is
        // live in wineserver, so no env-file support is involved.
        #expect(SettingReach.registry == .nextLaunch)
    }

    @Test
    func `a layer a prepend path can carry costs only the next launch`() {
        let engineReads = Engine.active.supportsEnvFiles
        #expect(SettingReach.renderer(.dxmt) == (engineReads ? .nextLaunch : .clientRestart))
        // Wine's own renderer has no payload directory to prepend, so it is
        // the client's to hand down however the engine reads its env files.
        #expect(SettingReach.renderer(.wined3d) == .clientRestart)
        // A game with no renderer of its own costs what any env key costs.
        #expect(SettingReach.renderer(nil) == SettingReach.env)
    }

    @Test
    func `an env key follows whether the engine reads the env files`() {
        #expect(SettingReach.env
            == (Engine.active.supportsEnvFiles ? .nextLaunch : .clientRestart))
    }
}
