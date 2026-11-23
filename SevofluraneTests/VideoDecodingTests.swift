import Foundation
import Testing
@testable import Sevoflurane

/// A game whose video decoder is fed and produces nothing: how the engine's
/// line is read, what a run keeps of it, how the setting reaches the engine,
/// and when the app offers the other decoder.
///
/// Serialized: the recorder's decoded-nothing hook is one static.
@MainActor
@Suite(.serialized)
struct VideoDecodingTests {
    private let manager = FileManager.default

    private static let runLine = "sevo:run pid=53056 exe=umamusumeprettyderby.exe appid=3224770 wpid=1a"
    private static let starvedLine = "0:00:06.777231125      53056   0x7ff206978000 ERROR                    WINE "
        + "wg_transform.c:1207:note_starved_transform: transform 0x7ff205e2d0a0 decoded none of 1030 buffers "
        + "(video/x-h264 -> video/x-raw)"
    private static let audioLine = "0:00:06.777231125      53056   0x7ff206978000 ERROR                    WINE "
        + "wg_transform.c:1207:note_starved_transform: transform 0x7ff205e2d0b0 decoded none of 40 buffers "
        + "(audio/mpeg -> audio/x-raw)"

    private static func record(
        t: String = "2026-10-31T20:00:00Z",
        appid: Int = 3_224_770,
        video: RunRecord.Video? = RunRecord.Video(buffers: 1030, stream: "video/x-h264", decoding: "hardware"),
        exit: RunRecord.Exit = RunRecord.Exit(kind: .user, code: 0),
    ) -> RunRecord {
        RunRecord(
            t: t,
            appid: appid,
            name: "Umamusume",
            engine: "dormison-r9",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            macos: "27.0",
            durationSeconds: 90,
            exit: exit,
            video: video,
            host: RunRecord.Host(thermal: "nominal", load: 1.2),
        )
    }

    private static func freshDefaults() -> UserDefaults {
        let suite = "VideoDecodingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private static func settings(decoding: VideoDecoding? = nil) -> InMemorySettingsEnvironment {
        var values = ConfigValues()
        values.videoDecoding = decoding
        return InMemorySettingsEnvironment(seed: [.game(3_224_770, bottle: SteamBottle.name): values])
    }

    // MARK: - The engine's line

    @Test
    func `the decoded-nothing line names the process, the count and the stream`() {
        let text = "0:00:01.000 1 0x1 WARN WINE wg_allocator.c:98:release_memory_sample: Copying\n"
            + Self.runLine + "\n" + Self.starvedLine + "\n" + Self.audioLine + "\n"
        let all = VideoStarvation.all(in: text)
        #expect(all == [
            VideoStarvation.Starved(pid: 53056, buffers: 1030, input: "video/x-h264", output: "video/x-raw"),
            VideoStarvation.Starved(pid: 53056, buffers: 40, input: "audio/mpeg", output: "audio/x-raw"),
        ])
        #expect(all[0].isVideo)
        #expect(!all[1].isVideo)
    }

    @Test
    func `only a video stream of the run's own processes counts`() {
        let text = Self.runLine + "\n" + Self.audioLine + "\n" + Self.starvedLine + "\n"
        #expect(VideoStarvation.video(forProcesses: [53056], in: text)?.buffers == 1030)
        #expect(VideoStarvation.video(forProcesses: [1], in: text) == nil)
        #expect(VideoStarvation.video(forApp: 3_224_770, in: text)?.stream == "video/x-h264")
        #expect(VideoStarvation.video(forApp: 3_224_770, in: text)?.decoding == "hardware")
        #expect(VideoStarvation.video(forApp: 1, in: text) == nil)
        #expect(VideoStarvation.video(forApp: 3_224_770, in: Self.audioLine) == nil)
    }

    // MARK: - The setting

    @Test
    func `hardware unsets the ranks and software ranks VideoToolbox out`() {
        #expect(ConfigMaterializer.videoDecodingLine(.hardware) == "GST_PLUGIN_FEATURE_RANK=")
        #expect(ConfigMaterializer.videoDecodingLine(.software) == "GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtdec:NONE")
        var values = ConfigValues.empty
        #expect(!ConfigMaterializer.gameLines(1, values).contains { $0.hasPrefix("GST_PLUGIN_FEATURE_RANK") })
        values.videoDecoding = .software
        #expect(ConfigMaterializer.gameLines(1, values).contains("GST_PLUGIN_FEATURE_RANK=vtdec_hw:NONE,vtdec:NONE"))
        values.videoDecoding = .hardware
        #expect(ConfigMaterializer.gameLines(1, values).contains("GST_PLUGIN_FEATURE_RANK="))
        #expect(GameConfig.defaults.videoDecoding == .hardware)
        #expect(VideoDecoding.hardware.other == .software)
        #expect(VideoDecoding.software.other == .hardware)
    }

    // MARK: - What a run keeps

    @Test
    func `the starved video survives a round trip and stays out of the shared run`() throws {
        let record = Self.record()
        let encoded = try JSONEncoder().encode(record)
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let video = try #require(json["video"] as? [String: Any])
        #expect(video["buffers"] as? Int == 1030)
        #expect(video["stream"] as? String == "video/x-h264")
        #expect(video["decoding"] as? String == "hardware")
        #expect(try JSONDecoder().decode(RunRecord.self, from: encoded) == record)
        #expect(record.summary.contains("video decoded nothing (video/x-h264, 1030 buffers, hardware)"))
        #expect(record.displaySummary.contains("video decoded nothing"))
        #expect(!Self.record(video: nil).summary.contains("video"))

        let shared = try #require(SharedRun(record: record, appVersion: "1.0 (1)"))
        let sharedJSON = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(shared)) as? [String: Any],
        )
        #expect(sharedJSON["video"] == nil)
    }

    @Test
    func `the recorder reads the line while the run is up, says so once, and keeps it at the close`() async throws {
        let root = manager.temporaryDirectory.appendingPathComponent("video-decoding-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(
            runs: root, wineLog: wine, processLog: root.appendingPathComponent("gameprocess_log.txt"),
        )
        nonisolated(unsafe) var starved: [RunRecord] = []
        let previous = RunRecorder.didStarveVideo
        RunRecorder.didStarveVideo = { starved.append($0) }
        defer { RunRecorder.didStarveVideo = previous }

        let appID = 3_224_770
        recorder.arm(appID: appID)
        recorder.noteExecutable("umamusumeprettyderby.exe", pid: getpid(), forApp: appID)
        try (Self.runLine + "\n" + Self.starvedLine + "\n").write(to: wine, atomically: true, encoding: .utf8)
        for _ in 0 ..< 2 {
            let read = try #require(recorder.provenanceReads.first { $0.appID == appID })
            let (lines, end) = RunRecorder.provenance(in: wine, from: read.offset)
            recorder.noteProvenance(lines, readTo: end, for: read)
        }
        #expect(starved.count == 1)
        #expect(starved.first?.video == RunRecord.Video(buffers: 1030, stream: "video/x-h264", decoding: "hardware"))

        recorder.close(appID: appID)
        var records: [RunRecord] = []
        for _ in 0 ..< 100 {
            records = RunLog.records(inMonth: .now, in: root)
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(records.first?.video?.buffers == 1030)
        #expect(starved.count == 1)
    }

    @Test
    func `a run closed before the log was read still keeps the line`() async throws {
        let root = manager.temporaryDirectory.appendingPathComponent("video-decoding-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(
            runs: root, wineLog: wine, processLog: root.appendingPathComponent("gameprocess_log.txt"),
        )
        let appID = 3_224_770
        recorder.arm(appID: appID)
        try (Self.runLine + "\n" + Self.starvedLine + "\n").write(to: wine, atomically: true, encoding: .utf8)
        recorder.close(appID: appID)
        var records: [RunRecord] = []
        for _ in 0 ..< 100 {
            records = RunLog.records(inMonth: .now, in: root)
            if !records.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(20))
        }
        #expect(records.first?.video?.stream == "video/x-h264")
    }

    // MARK: - The diagnosis

    @Test
    func `a starved run on hardware is offered software, and the other way round`() {
        let onHardware = VideoDecodingDiagnosis.suggestion(for: Self.record(), current: .hardware)
        #expect(onHardware?.offered == .software)
        let software = RunRecord.Video(buffers: 300, stream: "video/x-h264", decoding: "software")
        let onSoftware = VideoDecodingDiagnosis.suggestion(for: Self.record(video: software), current: .software)
        #expect(onSoftware?.offered == .hardware)
    }

    @Test
    func `a run that decoded, or a decoding changed since, is left alone`() {
        #expect(VideoDecodingDiagnosis.suggestion(for: Self.record(video: nil), current: .hardware) == nil)
        #expect(VideoDecodingDiagnosis.suggestion(for: Self.record(), current: .software) == nil)
    }

    // MARK: - The offer

    private final class Shown {
        var causes: [[RunDiagnosis.Cause]] = []
    }

    private static func prompt(
        defaults: UserDefaults = freshDefaults(), settings: InMemorySettingsEnvironment = settings(),
    ) -> (RunDiagnosisPrompt, Shown) {
        let shown = Shown()
        let prompt = RunDiagnosisPrompt(defaults: defaults, settings: settings, suggested: { [] }) {
            shown.causes.append($1.map(\.cause))
        }
        return (prompt, shown)
    }

    @Test
    func `a starved run opens the panel once, while it runs or at its close`() {
        let (prompt, shown) = Self.prompt()
        var open = Self.record()
        open.exit = nil
        #expect(prompt.offer(open))
        #expect(!prompt.offer(Self.record()))
        #expect(!prompt.offer(Self.record()))
        #expect(shown.causes == [[.videoDecodedNothing]])
    }

    @Test
    func `a run told of its video while it was up is told of its crash at the close`() {
        let (prompt, shown) = Self.prompt()
        var open = Self.record()
        open.exit = nil
        #expect(prompt.offer(open))
        #expect(prompt.offer(Self.record(exit: RunRecord.Exit(kind: .crash, code: 3))))
        #expect(shown.causes == [[.videoDecodedNothing], [.crashed]])
    }

    @Test
    func `the video leads a crash and the processor limit in one panel`() {
        let (prompt, shown) = Self.prompt()
        var run = Self.record(exit: RunRecord.Exit(kind: .crash, code: 3))
        run.threads = RunRecord.Threads(busy: 15, processors: 16, samples: 30)
        #expect(prompt.offer(run))
        #expect(shown.causes == [[.videoDecodedNothing, .crashed, .threadSpin]])
    }

    @Test
    func `a game muted stays quiet, and a game already switched is not offered`() {
        let defaults = Self.freshDefaults()
        let (prompt, shown) = Self.prompt(defaults: defaults)
        Preferences.stopAsking(about: .videoDecodedNothing, forApp: 3_224_770, in: defaults)
        #expect(!prompt.offer(Self.record()))
        #expect(shown.causes.isEmpty)
        #expect(Preferences.quietCauses(forApp: 3_224_770, in: defaults) == [.videoDecodedNothing])
        #expect(Preferences.quietCauses(forApp: 1, in: defaults).isEmpty)
        // The mute an installed app wrote is read.
        #expect(defaults.array(forKey: "quietVideoDecodingApps") as? [Int] == [3_224_770])

        let (switched, shownSwitched) = Self.prompt(settings: Self.settings(decoding: .software))
        #expect(!switched.offer(Self.record()))
        #expect(shownSwitched.causes.isEmpty)
    }

    @Test
    func `taking the offer writes the other decoder to the game's settings`() {
        let settings = Self.settings()
        let record = Self.record()
        let model = RunDiagnosisModel(
            record: record, findings: RunDiagnosis.findings(for: record),
            defaults: Self.freshDefaults(), settings: settings, ledger: nil,
        )
        var finished = 0
        model.onFinish = { finished += 1 }
        #expect(model.headline.action?.label == "Use Software Decoding")
        #expect(model.headline.sentence.contains("Umamusume"))
        model.perform(model.headline)
        #expect(settings.values(.game(3_224_770, bottle: SteamBottle.name)).videoDecoding == .software)
        #expect(finished == 1)
    }
}
