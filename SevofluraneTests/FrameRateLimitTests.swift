import Foundation
import Testing
@testable import Sevoflurane

/// The frame rate limit and the counter's detail: what a running game's View
/// menu stores through `sevo`, and what the engine reads back.
struct FrameRateLimitTests {
    @Test
    func `every value View › Frame Rate Limit stores reads back as the rate it names`() {
        // dormison cocoa_app.m: `off`, or the rate as "%d".
        let sent = ["off": 0, "30": 30, "40": 40, "45": 45, "60": 60, "90": 90, "120": 120]
        for (value, rate) in sent {
            #expect(FrameRateLimit(rawValue: value)?.framesPerSecond == rate, "\(value)")
        }
        #expect(FrameRateLimit.allCases.count == sent.count)
        for value in ["0", "on", "144", "60 fps", ""] {
            #expect(FrameRateLimit(rawValue: value) == nil, "\(value)")
        }
    }

    @Test
    func `every level View › Overlay Detail stores reads back as that level`() {
        for level in 1 ... 3 {
            #expect(OverlayDetail(rawValue: String(level))?.level == level)
        }
        for value in ["0", "4", "on", "frameTime", ""] {
            #expect(OverlayDetail(rawValue: value) == nil, "\(value)")
        }
    }

    @Test
    func `the bottle writes both, and no limit is a zero`() {
        let lines = ConfigMaterializer.bottleLines(SteamBottle.name)
        #expect(lines.contains { $0.hasPrefix("SEVO_OVERLAY_LEVEL=") })
        #expect(lines.contains { $0.hasPrefix("SEVO_FPS_LIMIT=") })
        #expect(GameConfig.defaults.frameRateLimit == .off)
        #expect(GameConfig.defaults.overlayDetail == .frameRate)
    }

    @Test
    func `a game writes the limit and the level it sets, off included`() {
        var values = ConfigValues.empty
        #expect(!ConfigMaterializer.gameLines(1, values).contains { $0.hasPrefix("SEVO_FPS_LIMIT=") })
        values.frameRateLimit = .fps45
        values.overlayDetail = .system
        var lines = ConfigMaterializer.gameLines(1, values)
        #expect(lines.contains("SEVO_FPS_LIMIT=45"))
        #expect(lines.contains("SEVO_OVERLAY_LEVEL=3"))
        // Off is written so a game asking for none overrides a bottle that limits.
        values.frameRateLimit = .off
        lines = ConfigMaterializer.gameLines(1, values)
        #expect(lines.contains("SEVO_FPS_LIMIT=0"))
    }

    @Test
    func `fps-graph sets the level, and shows the counter only when it was hidden`() {
        var values = ConfigValues.empty
        values.setFrameGraph(true, counterShown: false)
        #expect(values.overlayDetail == .frameTime)
        #expect(values.fps == true)

        values = .empty
        values.setFrameGraph(true, counterShown: true)
        #expect(values.overlayDetail == .frameTime)
        #expect(values.fps == nil)

        values.setFrameGraph(false, counterShown: true)
        #expect(values.overlayDetail == .frameRate)
        #expect(OverlayDetail.frameRate.showsFrameGraph == false)
        #expect(OverlayDetail.system.showsFrameGraph)

        values.setFrameGraph(nil, counterShown: true)
        #expect(values.overlayDetail == nil)
    }
}
