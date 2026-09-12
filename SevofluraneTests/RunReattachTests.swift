import Foundation
import Testing
@testable import Sevoflurane

/// What a launch leaves behind when the app that opened it is killed: a run
/// armed on disk, picked up by the next process and closed honestly.
struct RunReattachTests {
    private let manager = FileManager.default

    /// A scratch `Runs` directory, removed by the caller.
    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("run-reattach-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A recorder whose records, armed runs and both logs live in `root`, so
    /// nothing it does reaches this Mac's own.
    private func makeRecorder(in root: URL) throws -> RunRecorder {
        let wine = root.appendingPathComponent("wine.log")
        if !manager.fileExists(atPath: wine.path) { try Data().write(to: wine) }
        return RunRecorder(runs: root, wineLog: wine, processLog: processLogURL(in: root))
    }

    private func processLogURL(in root: URL) -> URL {
        root.appendingPathComponent("gameprocess_log.txt")
    }

    /// Steam's process log for one app, with or without the exit it recorded.
    @discardableResult
    private func writeProcessLog(in root: URL, appID: Int, exit code: Int?) throws -> URL {
        var text = """
        [2026-09-11 17:23:09] AppID \(appID) adding PID 1400 as a tracked process \
        ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\HK\\hollow_knight.exe""

        """
        if let code {
            text += "[2026-09-11 17:23:34] AppID \(appID) "
                + "no longer tracking PID 1400, exit code \(code)\n"
        }
        let url = processLogURL(in: root)
        try Data(text.utf8).write(to: url)
        return url
    }

    /// The record write leaves the caller's thread, so a test waits for it
    /// rather than for a fixed delay.
    private func records(in root: URL, waitingFor count: Int) async -> [RunRecord] {
        for _ in 0 ..< 100 {
            let records = RunLog.records(inMonth: .now, in: root)
            if records.count >= count { return records }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return RunLog.records(inMonth: .now, in: root)
    }

    @Test
    func `an armed run is on disk before anything closes it`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        try makeRecorder(in: root).arm(appID: 367_520)
        let armed = RunLog.armedRuns(in: root)
        #expect(armed.count == 1)
        #expect(armed.first?.record.appid == 367_520)
        #expect(RunLog.records(inMonth: .now, in: root).isEmpty)
    }

    @Test
    func `a game the client is still running stays open under a new recorder`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        try makeRecorder(in: root).arm(appID: 367_520)
        try writeProcessLog(in: root, appID: 367_520, exit: nil)

        let relaunched = try makeRecorder(in: root)
        relaunched.reattach()
        #expect(RunLog.records(inMonth: .now, in: root).isEmpty)
        #expect(RunLog.armedRuns(in: root).count == 1)

        // The quit takes the bottle down with the app, and Steam never wrote
        // an exit, so that is what the record says.
        relaunched.closeAll()
        let records = RunLog.records(inMonth: .now, in: root)
        #expect(records.count == 1)
        #expect(records.first?.exit?.kind == .appQuit)
        #expect(records.first?.appid == 367_520)
        #expect(RunLog.armedRuns(in: root).isEmpty)
    }

    @Test
    func `a game that ended while the app was gone is recorded at the next launch`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        try makeRecorder(in: root).arm(appID: 367_520)
        try writeProcessLog(in: root, appID: 367_520, exit: 0)

        try makeRecorder(in: root).reattach()
        let records = await records(in: root, waitingFor: 1)
        #expect(records.count == 1)
        #expect(records.first?.exit?.kind == .user)
        #expect(records.first?.exit?.code == 0)
        #expect(RunLog.armedRuns(in: root).isEmpty)
    }

    @Test
    func `a run whose client session is over is recorded with no exit to name`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        try makeRecorder(in: root).arm(appID: 367_520)
        // Steam rewrites its process log at each client start, so a log
        // without the app in it belongs to a session that is over.
        try writeProcessLog(in: root, appID: 480, exit: 0)

        try makeRecorder(in: root).reattach()
        let records = await records(in: root, waitingFor: 1)
        #expect(records.count == 1)
        #expect(records.first?.exit?.kind == .unknown)
    }

    @Test
    func `an armed run carries what the launch learned after it began`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: 367_520)
        recorder.noteExecutable("hollow_knight.exe", forApp: 367_520)
        recorder.noteWindowUp(forApp: 367_520)
        let armed = try #require(RunLog.armedRuns(in: root).first)
        #expect(armed.record.exe == "hollow_knight.exe")
        #expect(armed.record.windowAfterSeconds != nil)
        #expect(armed.started.timeIntervalSinceNow < 1)
    }

    @Test
    func `an app with no line of its own is not tracked`() {
        let log = "[2026-09-11 17:23:09] AppID 480 adding PID 1400 as a tracked process \"\"a.exe\"\""
        #expect(SteamGameProcessLog.tracks(app: 480, in: log))
        #expect(!SteamGameProcessLog.tracks(app: 367_520, in: log))
        #expect(!SteamGameProcessLog.tracks(app: 480, in: ""))
    }
}
