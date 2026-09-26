import CryptoKit
import Foundation
import Testing
@testable import Sevoflurane

/// What a run sends to the community database, and the identity it is sent under.
struct SharedRunTests {
    @Test
    func `a run with every field set sends exactly the wire keys and nothing that names anyone`() throws {
        let run = try #require(SharedRun(record: Self.fullRecord(), appVersion: "1.14"))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stats.encode(run)) as? [String: Any])
        #expect(Set(object.keys) == [
            "v", "t", "app", "appid", "exe", "engine", "renderer", "runner", "arch", "runtime", "settings",
            "macos", "chip", "mac", "gpu_cores", "memory_gb", "resolution", "window_after_s", "duration_s",
            "display", "gameplay_s", "fps", "stalls", "exit", "crashed", "game_mode", "host_load",
        ])
        let text = try String(decoding: JSONEncoder.stats.encode(run), as: UTF8.self)
        for private_ in ["Secret Game Title", "/Users/", "C:\\\\", "0xdeadbeef", "a renderer note"] {
            #expect(!text.contains(private_))
        }
        #expect(run.v == 2)
        #expect(run.t == "2026-09-25T14:00:00Z")
        #expect(run.exe == "Game-Win64-Shipping.exe")
        #expect(run.fps?.p99Milliseconds == 24.5)
        #expect(run.crashed)
    }

    @Test
    func `the shared frame rate is the gameplay's, never the whole run's`() throws {
        let run = try #require(SharedRun(record: Self.fullRecord(), appVersion: "1.14"))
        #expect(run.fps?.avg == 61.5)
        #expect(run.fps?.low1 == 48)
        #expect(run.fps?.samples == 812)
        #expect(run.gameplaySeconds == 812)
        #expect(run.display == RunRecord.Display(refreshHz: 120, variable: true, virtual: false))
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder.stats.encode(run)) as? [String: Any])
        #expect(object["display"] as? [String: AnyHashable] == ["refresh_hz": 120, "variable": true, "virtual": false])
    }

    @Test
    func `a run without a long enough gameplay window, or on a virtual display, sends no frame rate`() throws {
        var record = Self.fullRecord()
        record.fps?.gameplay?.seconds = 21
        record.fps?.gameplay?.frameTimes = nil
        var run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.fps == nil)
        #expect(run.gameplaySeconds == 21)

        record = Self.fullRecord()
        record.fps?.gameplay = nil
        run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.fps == nil)
        #expect(run.gameplaySeconds == 0)

        record = Self.fullRecord()
        record.display = nil
        run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.fps == nil)

        record = Self.fullRecord()
        record.display?.virtual = true
        run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.fps == nil)
        #expect(run.display?.virtual == true)
    }

    @Test
    func `a crash on the way out is not shared as a crash`() throws {
        var record = Self.fullRecord()
        record.exit = RunRecord.Exit(kind: .crashAtExit, code: -1073740791)
        let run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.exit == "crash-at-exit")
        #expect(!run.crashed)
    }

    @Test
    func `a program Steam does not know sends its product name in place of an appid`() throws {
        var record = Self.fullRecord()
        record.appid = AdoptedPrograms.firstID + 3
        let run = try #require(SharedRun(record: record, appVersion: "1.14"))
        #expect(run.appid == nil)
        #expect(run.product == "Genshin Impact")
    }

    @Test
    func `a short run that never drew is not sent, a short run that drew is`() {
        var record = Self.fullRecord()
        record.windowAfterSeconds = nil
        record.fps = nil
        record.durationSeconds = 8
        #expect(SharedRun(record: record, appVersion: "1.14") == nil)
        record.durationSeconds = 25
        #expect(SharedRun(record: record, appVersion: "1.14") != nil)
        record.durationSeconds = 3
        record.windowAfterSeconds = 2
        #expect(SharedRun(record: record, appVersion: "1.14") != nil)
    }

    @Test
    func `base32 matches RFC 4648 and the install id is derived from the key`() {
        #expect(Base32.encode(Data("foobar".utf8)) == "mzxw6ytboi")
        #expect(Base32.encode(Data("f".utf8)) == "my")
        let key = P256.Signing.PrivateKey().publicKey.derRepresentation
        let id = StatsIdentity.installID(publicKeyDER: key)
        #expect(id.count == 26)
        #expect(id == StatsIdentity.installID(publicKeyDER: key))
    }

    @Test
    func `memory rounds to the nearest size Apple sells`() {
        let gib: UInt64 = 1_073_741_824
        #expect(MacHardware.memoryTier(bytes: 64 * gib) == 64)
        #expect(MacHardware.memoryTier(bytes: 36 * gib - 200_000_000) == 36)
        #expect(MacHardware.memoryTier(bytes: 17 * gib) == 16 || MacHardware.memoryTier(bytes: 17 * gib) == 18)
    }

    @Test
    func `a service that is not there stops the sends, anything else backs off`() {
        let classOf = { StatsUploader.failureClass(of: $0) }
        for status in [404, 410, 501] {
            #expect(classOf(StatsUploader.Failure.refused(status: status, reason: nil)) == .serviceAbsent)
        }
        #expect(classOf(StatsUploader.Failure.refused(status: 503, reason: nil)) == .serverError)
        #expect(classOf(StatsUploader.Failure.refused(status: 400, reason: "bad")) == .refused)
        #expect(classOf(StatsUploader.Failure.unreachable("offline")) == .unreachable)
        #expect((0 ..< 7).map(StatsUploader.wait(afterFailures:))
            == [.seconds(60), .seconds(300), .seconds(1800), .seconds(7200), .seconds(21600), .seconds(21600), .seconds(21600)])
    }

    @Test
    func `a state written before the backoff was kept still reads, sequence and all`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data(#"{"registered":"abc","seq":41,"sentRuns":3}"#.utf8).write(to: url)
        let state = StatsStore.readState(from: url)
        #expect(state.seq == 41)
        #expect(state.failures == nil)
        var next = state
        next.failures = 2
        next.nextTry = Date(timeIntervalSince1970: 1_790_000_000)
        StatsStore.writeState(next, to: url)
        #expect(StatsStore.readState(from: url) == next)
    }

    @Test
    func `the queue survives a round trip through its file`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("queue-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        let run = try #require(SharedRun(record: Self.fullRecord(), appVersion: "1.14"))
        let queued = StatsStore.Queued(queued: Date(timeIntervalSince1970: 1_790_000_000), run: run)
        StatsStore.writeQueue([queued, queued], to: url)
        #expect(StatsStore.readQueue(from: url) == [queued, queued])
    }

    private static func fullRecord() -> RunRecord {
        RunRecord(
            t: "2026-09-25T14:12:06Z", appid: 1_962_700, name: "Secret Game Title",
            exe: "Game-Win64-Shipping.exe", engine: "dormison-r16", renderer: "d3dmetal", runner: "wine",
            arch: 64, windows: "fixed", tuning: "standard", upscaler: "lanczos", msync: true,
            d3dmetal: "4.0 beta 2", runtime: "unreal", macos: "27.0.0", chip: "Apple M4 Max", mac: "Mac16,5",
            gpuCores: 40, memoryGB: 64, product: "Genshin Impact", windowAfterSeconds: 6.2, durationSeconds: 900,
            fps: RunRecord.FrameRate(
                avg: 60, low1: 42, samples: 880,
                frameTimes: FrameStats.Summary(
                    frames: 54000, seconds: 900, avg: 60, low1: 42, low01: 30, p50: 16.6, p95: 20, p99: 24.5,
                    p999: 40, max: 80, stdev: 2, hitches: 3,
                ),
                trace: "/Users/someone/Library/trace.csv",
                gameplay: RunRecord.Gameplay(
                    from: 31.5, seconds: 812, away: 40, gaps: 2,
                    frameTimes: FrameStats.Summary(
                        frames: 49938, seconds: 812, avg: 61.5, low1: 48, low01: 33, p50: 16.2, p95: 18, p99: 24.5,
                        p999: 35, max: 60, stdev: 1.5, hitches: 2,
                    ),
                ),
            ),
            resolution: RunRecord.Resolution(window: RunRecord.Pixels(width: 3456, height: 2234)),
            display: RunRecord.Display(refreshHz: 120, variable: true, virtual: false),
            stalls: [RunRecord.Stall(at: 30, duration: 4, unwedged: nil)],
            exit: RunRecord.Exit(kind: .crash, code: -1),
            crash: RunRecord.Crash(code: "0xc0000005", flags: nil, address: "0xdeadbeef", module: "C:\\\\game.exe"),
            notes: ["a renderer note"], gameMode: true,
            host: RunRecord.Host(thermal: "nominal", load: 2),
        )
    }
}
