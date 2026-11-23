import Foundation
import Testing
@testable import Sevoflurane

/// How a program's launch reaches the Steam host, from whichever store
/// started it.
@MainActor
struct QuickLaunchStoreTests {
    /// A host that writes the beats down instead of acting on them.
    private final class RecordingReporter: ProgramLaunchReporting {
        var beats: [String] = []

        var open: (appID: Int, ticket: UUID)?

        func beginProgramLaunch(appID: Int) -> UUID? {
            if open?.appID == appID { return nil }
            let ticket = UUID()
            open = (appID, ticket)
            beats.append("pressed \(appID)")
            return ticket
        }

        func programDidStart(appID: Int) { beats.append("started \(appID)") }

        func endProgramLaunch(appID: Int, ticket: UUID?) {
            guard let ticket, open?.appID == appID, open?.ticket == ticket else { return }
            open = nil
            beats.append("ended \(appID)")
        }
    }

    /// A Dock tile's launch used to fall back to a store with no hooks when
    /// the popover was not up yet, and recorded nothing (2026-09-26); every
    /// store is wired through this one initializer now.
    @Test
    func `the hooks tell the host the press and a launch the helper refused`() {
        let host = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)
        let ticket = hooks.pressed(2_000_000_001)
        hooks.ended(2_000_000_001, ticket)
        #expect(host.beats == ["pressed 2000000001", "ended 2000000001"])
    }

    // MARK: - The helper's start notice

    /// The start is told once per launch, by the helper: after the press for
    /// a launch this app asked for, and alone for one `sevo program launch`
    /// or the MCP server asked for.
    @Test
    func `the helper's notice is the one start of a launch, pressed here or not`() throws {
        let notice = try #require(ProgramStartNotice(query: "id=2000000001"))
        let pressedHere = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: pressedHere)
        _ = hooks.pressed(2_000_000_001)
        pressedHere.take(notice)
        #expect(pressedHere.beats == ["pressed 2000000001", "started 2000000001"])

        let fromTheCommandLine = RecordingReporter()
        fromTheCommandLine.take(notice)
        #expect(fromTheCommandLine.beats == ["started 2000000001"])
    }

    /// A host whose start arms a real recorder, as the app's does.
    private final class ArmingReporter: ProgramLaunchReporting {
        let recorder: RunRecorder

        init(recorder: RunRecorder) {
            self.recorder = recorder
        }

        func beginProgramLaunch(appID: Int) -> UUID? {
            recorder.noteLaunchPressed(appID: appID)
            return UUID()
        }

        func programDidStart(appID: Int) { recorder.arm(appID: appID) }

        func endProgramLaunch(appID _: Int, ticket _: UUID?) {}
    }

    @Test
    func `a launch opens one run, and the helper's word of a failed driver finds it`() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent("program-start-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        let wine = root.appendingPathComponent("wine.log")
        try Data().write(to: wine)
        let recorder = RunRecorder(runs: root, wineLog: wine, processLog: root.appendingPathComponent("p.txt"))
        let host = ArmingReporter(recorder: recorder)
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)

        // This app's own launch: the press, the helper's notice, then a reply that reports nothing.
        _ = hooks.pressed(2_000_000_001)
        try host.take(#require(ProgramStartNotice(query: "id=2000000001")))
        // A launch from the command line: the notice alone.
        try host.take(#require(ProgramStartNotice(query: "id=2000000002")))

        #expect(RunLog.armedRuns(in: root).map(\.record.appid).sorted() == [2_000_000_001, 2_000_000_002])
        #expect(recorder.closedRuns == 0)
        let record = try #require(recorder.noteKernelDriver("HoYoKProtect.sys", forApp: 2_000_000_002))
        #expect(record.driver == "HoYoKProtect.sys")
    }

    @Test
    func `a start notice names an added program and nothing else`() {
        let notice = ProgramStartNotice(programID: 2_000_000_007)
        #expect(notice.target == "/program/starting?id=2000000007")
        #expect(ProgramStartNotice(query: "id=2000000007") == notice)
        // A Steam app id, a word and an empty query open no run.
        #expect(ProgramStartNotice(query: "id=413150") == nil)
        #expect(ProgramStartNotice(query: "id=Game.exe") == nil)
        #expect(ProgramStartNotice(query: "") == nil)
    }

    @Test
    func `the helper's reply says whether the app opened a run`() throws {
        let recorded = try JSONDecoder().decode(
            ProgramLaunchReply.self, from: JSONEncoder().encode(ProgramLaunchReply(recorded: true)),
        )
        #expect(recorded == ProgramLaunchReply(recorded: true))
        #expect(recorded.summary(of: "Genshin Impact") == "Genshin Impact started")
        let json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(ProgramLaunchReply(recorded: false)),
        ) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(json["note"] as? String == "program started")
        #expect(json["recorded"] as? Bool == false)
        #expect(ProgramLaunchReply(recorded: false).summary(of: "Genshin Impact")
            == "Genshin Impact started, with no run record: the app was not there to open one")
    }

    /// A Dock tile's launch was in flight when the row was pressed again; the
    /// daemon answered the press 409, and its end cleared the first launch's
    /// line, so the window and the frames that followed had no launch to
    /// belong to (review, 2026-09-27).
    @Test
    func `a press made while a launch is under way owns no line and ends none`() {
        let host = RecordingReporter()
        let hooks = QuickLaunchStore.LaunchHooks(reporting: host)
        let first = hooks.pressed(2_000_000_001)
        let second = hooks.pressed(2_000_000_001)
        #expect(second == nil)
        hooks.ended(2_000_000_001, second)
        #expect(host.open?.ticket == first)
        hooks.ended(2_000_000_001, first)
        #expect(host.open == nil)
        #expect(host.beats == ["pressed 2000000001", "ended 2000000001"])
    }
}
