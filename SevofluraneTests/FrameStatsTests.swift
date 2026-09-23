import Foundation
import Testing
@testable import Sevoflurane

/// The frame-time statistics, their tests against reference values (scipy), the trace
/// file, the stats page's ring, and how runs group into configurations.
struct FrameStatsTests {
    // MARK: - One run

    @Test
    func `a steady run has its rate everywhere and no hitches`() throws {
        let summary = try #require(FrameStats.summarize(Array(repeating: 16.667, count: 600)))
        #expect(summary.frames == 600)
        #expect(summary.avg == 60)
        #expect(summary.low1 == 60)
        #expect(summary.p99 == 16.67)
        #expect(summary.hitches == 0)
    }

    @Test
    func `the 1 % low is the rate of the slowest hundredth, averaged`() throws {
        // 990 frames at 10 ms and 10 at 50 ms: the slowest 1 % is exactly the ten slow ones.
        let times = Array(repeating: Float(10), count: 990) + Array(repeating: Float(50), count: 10)
        let summary = try #require(FrameStats.summarize(times.shuffled()))
        #expect(summary.low1 == 20)
        #expect(summary.max == 50)
        #expect(summary.p50 == 10)
    }

    @Test
    func `a spike among steady frames is a hitch and a slow scene is not`() {
        var spiky = Array(repeating: Float(16.7), count: 200)
        spiky[100] = 60
        #expect(FrameStats.hitchCount(spiky) == 1)
        // Half the run at 16 ms and half at 33 ms: slower, but every frame is like its neighbors.
        let stepped = Array(repeating: Float(16), count: 200) + Array(repeating: Float(33), count: 200)
        #expect(FrameStats.hitchCount(stepped) == 0)
    }

    @Test
    func `frame rate per second counts the frames of each second`() {
        let rates = FrameStats.perSecond(Array(repeating: 10, count: 250))
        #expect(rates.count == 2)
        #expect(abs(rates[0] - 100) < 0.01)
    }

    // MARK: - Distributions

    @Test
    func `the incomplete beta and Student's t match scipy`() {
        #expect(abs(FrameStats.incompleteBeta(0.3, a: 2.5, b: 0.5) - 0.01892712407194565) < 1e-9)
        #expect(abs(FrameStats.studentTCDF(2.0, df: 7.5) - 0.9585515023509168) < 1e-7)
        #expect(abs(FrameStats.studentTQuantile(0.975, df: 5.3) - 2.527427788268117) < 1e-6)
    }

    @Test
    func `Welch's test matches scipy's ttest_ind with unequal variances`() throws {
        let difference = try #require(FrameStats.welch([60, 61, 59, 60.5], [65, 66, 64, 65.5]))
        #expect(abs(difference.delta - 5) < 1e-9)
        #expect(abs((difference.p ?? 1) - 0.00016793700357617104) < 1e-7)
        #expect(difference.isSignificant)
        #expect(difference.low > 0)
    }

    @Test
    func `runs that overlap are not called different`() throws {
        let difference = try #require(FrameStats.welch([60, 64, 58, 62], [61, 59, 63, 60]))
        #expect(!difference.isSignificant)
    }

    @Test
    func `the block bootstrap sees a real shift and is repeatable`() throws {
        var generator = SplitMix(seed: 7)
        let noisy = { (base: Float) in
            (0 ..< 3000).map { _ in base + Float(generator.next() % 400) / 100 }
        }
        let a = noisy(16), b = noisy(12)
        let first = try #require(FrameStats.blockBootstrap(a, b, statistic: FrameStats.averageRate))
        let again = try #require(FrameStats.blockBootstrap(a, b, statistic: FrameStats.averageRate))
        #expect(first == again)
        #expect(first.isSignificant && first.delta > 0)
        let same = try #require(FrameStats.blockBootstrap(a, a, statistic: FrameStats.averageRate))
        #expect(!same.isSignificant)
    }

    // MARK: - The trace

    @Test
    func `a trace reads back the frames it was given and the ones it lost`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trace-\(UUID().uuidString)/t.csv")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let writer = try #require(FrameTrace.Writer(url: url, appID: 7, stamp: "2026-09-23T10:00:00Z"))
        writer.append([16.5, 17.25])
        writer.noteDropped(3)
        writer.append([33.125])
        writer.close()
        let contents = try #require(FrameTrace.read(url))
        #expect(contents.frameTimes == [16.5, 17.25, 33.125])
        #expect(contents.dropped == 3)
        #expect(FrameTrace.name(appID: 7, stamp: "2026-09-23T10:00:00Z") == "2026-09-23T10-00-00Z-7.csv")
    }

    // MARK: - The stats page's ring

    @Test
    func `the ring is read from the offsets the engine writes it at`() throws {
        var page = Data(count: 4096)
        func put(_ value: some Any, at offset: Int) {
            withUnsafeBytes(of: value) { page.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt64(0x5345_564F_5354_5331), at: 0)
        put(UInt64(5), at: 8)
        put(UInt32(1), at: 48)
        put(UInt32(getpid()), at: 52)
        put(UInt32(1234), at: 60)
        put(UInt64(3), at: 104)
        put(UInt32(994), at: 112)
        for (index, stamp) in [UInt32(1000), 17667, 34333].enumerated() { put(stamp, at: 120 + index * 4) }

        let decoded = try #require(PresentStats.page(from: page))
        #expect(decoded.ringHead == 3)
        #expect(decoded.ringCapacity == 994)
        #expect(decoded.ring?.prefix(3) == [1000, 17667, 34333])
    }

    @Test
    func `a page from an engine without the ring has none`() throws {
        var page = Data(count: 104)
        withUnsafeBytes(of: UInt64(0x5345_564F_5354_5331)) { page.replaceSubrange(0 ..< 8, with: $0) }
        withUnsafeBytes(of: UInt32(1)) { page.replaceSubrange(48 ..< 52, with: $0) }
        let decoded = try #require(PresentStats.page(from: page))
        #expect(decoded.ring == nil)
    }

    // MARK: - Configurations

    private func run(engine: String, upscaler: String? = nil, label: String? = nil, fps: Float) -> PerfComparison.Run {
        PerfComparison.Run(
            record: RunRecord(
                t: "2026-09-23T10:00:00Z", appid: 1, engine: engine, renderer: "d3dmetal", runner: "wine",
                windows: "fixed", upscaler: upscaler, msync: true, macos: "27.0.0",
                host: .init(thermal: "nominal", load: 1),
            ),
            frameTimes: Array(repeating: 1000 / fps, count: 600), dropped: 0, trace: "t.csv", label: label,
        )
    }

    @Test
    func `runs group by what they ran on and are named by what differs`() {
        let groups = PerfComparison.groups([
            run(engine: "dormison-r15", fps: 60), run(engine: "dormison-r16", fps: 62),
            run(engine: "dormison-r15", fps: 61), run(engine: "dormison-r16", upscaler: "metalfx", fps: 70),
        ])
        #expect(groups.map(\.runs.count) == [2, 1, 1])
        #expect(groups.map(\.name) == [
            "dormison-r15 · upscaler off", "dormison-r16 · upscaler off", "dormison-r16 · upscaler metalfx",
        ])
    }

    @Test
    func `a label splits runs the record cannot tell apart`() {
        let groups = PerfComparison.groups([
            run(engine: "dormison-r16", label: "vsync on", fps: 60),
            run(engine: "dormison-r16", label: "vsync off", fps: 90),
        ])
        #expect(groups.map(\.name) == ["vsync on", "vsync off"])
    }

    @Test
    func `trimming keeps the seconds after the skip`() {
        let times = Array(repeating: Float(100), count: 100)
        #expect(PerfComparison.trim(times, skip: 2, duration: nil).count == 80)
        #expect(PerfComparison.trim(times, skip: 2, duration: 3).count == 30)
    }

    // MARK: - The record

    @Test
    func `a record keeps its tuning, upscaler and frame times through JSON`() throws {
        var record = run(engine: "dormison-r16", upscaler: "metalfx", fps: 60).record
        record.tuning = "experimental"
        record.fps = RunRecord.FrameRate(
            avg: 60, low1: 58, samples: 10,
            frameTimes: FrameStats.summarize(Array(repeating: 16.7, count: 100)), dropped: 2, trace: "t.csv",
        )
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
        let json = try String(decoding: JSONEncoder().encode(record), as: UTF8.self)
        #expect(json.contains("\"frame_times\""))
        #expect(json.contains("\"tuning\":\"experimental\""))
    }
}
