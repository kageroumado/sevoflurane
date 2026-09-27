import Foundation
import Testing
@testable import Sevoflurane

/// The gameplay window: what of a run's frames a frame rate is measured over. The real
/// traces are 9-nine-:Episode 1 (976390), a visual novel that renders every refresh, as the
/// app recorded them on 2026-09-23 and 26; they are what put 42 fps on its public page.
struct GameplayWindowTests {
    // MARK: - The recorded traces

    @Test
    func `a run stopped on the loading screen has no gameplay`() throws {
        #expect(try GameplayWindow.compute(Self.trace("2026-09-26T02-30-20Z")) == nil)
        #expect(try GameplayWindow.compute(Self.trace("2026-09-26T02-36-06Z")) == nil)
    }

    @Test
    func `the run that was played is measured from where loading ended`() throws {
        let window = try #require(GameplayWindow.compute(Self.trace("2026-09-26T00-43-41Z")))
        // Two seconds of nothing, then 874 and 102 ms frames while the scene loads, then play.
        #expect(abs(window.from - 12.25) < 0.01)
        #expect(abs(window.seconds - 81.6) < 0.1)
        #expect(window.gaps == 0)
        let gameplay = try #require(GameplayWindow.gameplay(of: Self.trace("2026-09-26T00-43-41Z")))
        let summary = try #require(gameplay.frameTimes)
        #expect(summary.avg == 107.9)
        #expect(summary.low1 == 17.9)
        #expect(summary.p99 == 35.42)
        // The whole trace, as the page had it: the loading screen pulls both down.
        let whole = try #require(FrameStats.summarize(Self.trace("2026-09-26T00-43-41Z").frameTimes))
        #expect(whole.avg < 105)
        #expect(whole.low1 < 12)
    }

    @Test
    func `runs shorter than half a minute of gameplay carry no frame rate`() throws {
        for stamp in ["2026-09-23T20-44-00Z", "2026-09-26T00-42-40Z"] {
            let gameplay = try #require(GameplayWindow.gameplay(of: Self.trace(stamp)))
            #expect(gameplay.seconds < 20)
            #expect(gameplay.frameTimes == nil)
        }
    }

    @Test
    func `a run on a virtual display has no gameplay`() throws {
        // Presenting uncapped at 150–340 fps: nothing paced it.
        var trace = try Self.trace("2026-09-26T02-51-33Z")
        let window = try #require(GameplayWindow.compute(trace))
        #expect(window.seconds > 50)
        trace.displays = [FrameTrace.DisplayChange(
            seconds: 0, display: RunRecord.Display(refreshHz: 60, variable: false, virtual: true),
        )]
        #expect(GameplayWindow.compute(trace) == nil)
    }

    // MARK: - The rules

    @Test
    func `gameplay starts ten seconds in on a game that is steady from its first frame`() throws {
        let window = try #require(GameplayWindow.compute(Self.steady(seconds: 60)))
        #expect(abs(window.from - 10) < 0.02)
        #expect(abs(window.seconds - 50) < 0.05)
    }

    @Test
    func `a loading screen that presents slowly holds the start back until frames come steadily`() throws {
        let loading = Array(repeating: Float(150), count: 134)
        let trace = FrameTrace.Contents(frameTimes: loading + Self.frames(seconds: 60), dropped: 0)
        let window = try #require(GameplayWindow.compute(trace))
        #expect(abs(window.from - 20.1) < 0.05)
    }

    @Test
    func `a game that never settles is measured from two minutes in, stutter and all`() throws {
        let trace = FrameTrace.Contents(frameTimes: Array(repeating: 120, count: 2000), dropped: 0)
        let window = try #require(GameplayWindow.compute(trace))
        #expect(abs(window.from - 120) < 0.2)
        #expect(window.frameTimes.allSatisfy { $0 == 120 })
    }

    @Test
    func `time in the background is left out, with the look's lag before it`() throws {
        var trace = Self.steady(seconds: 100)
        trace.focus = [
            FrameTrace.FocusChange(seconds: 0, focus: .hidden),
            FrameTrace.FocusChange(seconds: 1, focus: .focused),
            FrameTrace.FocusChange(seconds: 40, focus: .background),
            FrameTrace.FocusChange(seconds: 60, focus: .focused),
        ]
        let window = try #require(GameplayWindow.compute(trace))
        #expect(abs(window.away - 22) < 0.05)
        #expect(abs(window.seconds - 68) < 0.05)
    }

    @Test
    func `a frame slower than a quarter second is a gap, not gameplay`() throws {
        let trace = FrameTrace.Contents(
            frameTimes: Self.frames(seconds: 30) + [1500] + Self.frames(seconds: 30), dropped: 0,
        )
        let window = try #require(GameplayWindow.compute(trace))
        #expect(window.gaps == 1)
        #expect(!window.frameTimes.contains(1500))
        #expect(abs(window.seconds - 50) < 0.05)
    }

    @Test
    func `the recorded window equals the one read back from the trace file`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("gameplay-\(UUID().uuidString)/t.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try #require(FrameTrace.Writer(url: url, appID: 7, stamp: "2026-09-26T10:00:00Z"))
        writer.noteFocus(.hidden)
        writer.noteDisplay(RunRecord.Display(refreshHz: 120, variable: true, virtual: false))
        writer.append(Self.frames(seconds: 2))
        writer.noteFocus(.focused)
        writer.append(Self.frames(seconds: 40))
        writer.noteFocus(.asleep)
        writer.append([4000])
        writer.noteFocus(.focused)
        writer.append(Self.frames(seconds: 20))
        writer.close()
        let contents = try #require(FrameTrace.read(url))
        #expect(contents.focus.map(\.focus) == [.hidden, .focused, .asleep, .focused])
        #expect(contents.displays.first?.display == RunRecord.Display(refreshHz: 120, variable: true, virtual: false))
        #expect(abs((contents.focus.last?.seconds ?? 0) - 46) < 0.05)
        let gameplay = try #require(GameplayWindow.gameplay(of: contents))
        #expect(gameplay.from == 10)
        #expect(gameplay.away == 6)
        #expect(gameplay.frameTimes != nil)
    }

    @Test
    func `a game held to one rate has that rate as its steady rate, one that wanders has none`() {
        // Capped at 30: every frame within a millisecond of 33.3 ms.
        let capped = (0 ..< 1800).map { Float(33.33) + Float($0 % 3) - 1 }
        #expect(GameplayWindow.steadyRate(capped) == 30)
        // GPU-bound: 40 fps in one scene, 25 in the next.
        let bound = Array(repeating: Float(25), count: 900) + Array(repeating: Float(40), count: 900)
        #expect(GameplayWindow.steadyRate(bound) == nil)
    }

    @Test
    func `the played 9-nine run wandered too much to have held one rate`() throws {
        let gameplay = try #require(GameplayWindow.gameplay(of: Self.trace("2026-09-26T00-43-41Z")))
        #expect(gameplay.steadyFPS == nil)
    }

    // MARK: - The pages a run follows

    @Test
    func `a dead launch's page is not read into the next run's trace`() throws {
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("stale-\(UUID().uuidString)")
        let pages = prefix.appendingPathComponent(".sevo/run")
        try FileManager.default.createDirectory(at: pages, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: prefix) }
        let ended = Process()
        ended.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try ended.run()
        ended.waitUntilExit()
        try Self.page(pid: ended.processIdentifier, appID: 7, frames: 900)
            .write(to: pages.appendingPathComponent("\(ended.processIdentifier).stats"))
        let stats = PresentStats(prefix: prefix)
        stats.arm(appID: 7)
        defer { stats.disarm(appID: 7) }
        stats.sample()
        #expect(stats.reading(forApp: 7) == nil)
        try Self.page(pid: getpid(), appID: 7, frames: 12)
            .write(to: pages.appendingPathComponent("\(getpid()).stats"))
        stats.sample()
        #expect(stats.reading(forApp: 7)?.pid == getpid())
    }

    // MARK: - Displays

    @Test
    func `a display counts as hardware only when a framebuffer names its EDID identity`() {
        let studio: [String: Any] = [
            "LegacyManufacturerID": 1552, "ProductID": 44602, "SerialNumber": 4_250_532_600, "ProductName": "StudioDisplay",
        ]
        #expect(GameScreen.matches(studio, vendor: 1552, model: 44602, serial: 4_250_532_600))
        #expect(!GameScreen.matches(studio, vendor: 1552, model: 44602, serial: 7))
        // A CGVirtualDisplay reports whatever vendor and product its maker chose.
        #expect(!GameScreen.matches(studio, vendor: 0x3456, model: 0x1235, serial: 2))
        // A monitor that reports no serial matches on vendor and product.
        #expect(GameScreen.matches(["LegacyManufacturerID": 4268, "ProductID": 41136], vendor: 4268, model: 41136, serial: 0))
    }

    // MARK: - Helpers

    private static func trace(_ stamp: String) throws -> FrameTrace.Contents {
        let url = URL(filePath: #filePath).deletingLastPathComponent()
            .appending(path: "Fixtures/traces/\(stamp)-976390.csv")
        return try #require(FrameTrace.read(url))
    }

    private static func frames(seconds: Double, ms: Float = 1000 / 60) -> [Float] {
        Array(repeating: ms, count: Int((seconds * 1000 / Double(ms)).rounded()))
    }

    /// A stats page as the engine writes it, with `frames` presents in its ring.
    private static func page(pid: pid_t, appID: Int, frames: Int) -> Data {
        var page = Data(count: 4096)
        func put(_ value: some Any, at offset: Int) {
            withUnsafeBytes(of: value) { page.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt64(0x5345_564F_5354_5331), at: 0)
        put(UInt64(frames), at: 8)
        put(UInt32(1), at: 48)
        put(UInt32(pid), at: 52)
        put(UInt32(appID), at: 60)
        put(UInt64(frames), at: 104)
        put(UInt32(994), at: 112)
        for index in 0 ..< min(frames, 994) { put(UInt32(index * 8333), at: 120 + index * 4) }
        return page
    }

    private static func steady(seconds: Double) -> FrameTrace.Contents {
        FrameTrace.Contents(frameTimes: frames(seconds: seconds), dropped: 0)
    }
}
