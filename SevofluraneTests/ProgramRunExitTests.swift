import Foundation
import Testing
@testable import Sevoflurane

/// How a Quick Launch program's run learns its exit: Steam never started the
/// program, so its process log has no line for it, and the helper writes the
/// launcher's status to the Wine log instead (``ProgramExit``).
struct ProgramRunExitTests {
    private let manager = FileManager.default
    /// An id in the adopted range, which is what makes a run a program's.
    private let program = 2_000_000_001
    private let genshin = ProgramExit.Program(appID: 2_000_000_001, exe: "GenshinImpact.exe")

    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("program-run-exit-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A recorder on fixture logs in `root`, giving a program's exit line
    /// `grace` to arrive.
    private func makeRecorder(in root: URL, grace: Duration = .zero) throws -> RunRecorder {
        let wine = root.appendingPathComponent("wine.log")
        if !manager.fileExists(atPath: wine.path) { try Data().write(to: wine) }
        return RunRecorder(
            runs: root, wineLog: wine, processLog: root.appendingPathComponent("gameprocess_log.txt"),
            programExitGrace: grace,
        )
    }

    private func append(_ line: String, in root: URL) throws {
        let wine = root.appendingPathComponent("wine.log")
        let handle = try FileHandle(forWritingTo: wine)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((line + "\n").utf8))
    }

    private func records(in root: URL, waitingFor count: Int) async -> [RunRecord] {
        for _ in 0 ..< 200 {
            let records = RunLog.records(inMonth: .now, in: root)
            if records.count >= count { return records }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return RunLog.records(inMonth: .now, in: root)
    }

    @Test
    func `the line as the helper writes it reads back by app id`() {
        let line = ProgramExit.line(genshin, status: 0)
        #expect(line == "sevo:program-exit appid=2000000001 exe=GenshinImpact.exe status=0")
        #expect(ProgramExit.status(forApp: program, in: line) == 0)
        #expect(ProgramExit.status(forApp: 2_000_000_002, in: line) == nil)
        #expect(ProgramExit.status(forApp: program, in: "sevo:run pid=1 exe=a.exe appid=none engine=r20") == nil)
    }

    @Test
    func `an executable with spaces in its name still yields its status`() {
        let line = ProgramExit.line(.init(appID: program, exe: "Blue Archive.exe"), status: -5)
        #expect(ProgramExit.status(forApp: program, in: "fixme:d3d:something\n" + line) == -5)
    }

    @Test
    func `the last line for the program is the one that counts`() {
        let trail = [
            ProgramExit.line(genshin, status: 1),
            ProgramExit.line(.init(appID: 2_000_000_002, exe: "bgi.exe"), status: 7),
            ProgramExit.line(genshin, status: 0),
        ].joined(separator: "\n")
        #expect(ProgramExit.status(forApp: program, in: trail) == 0)
        #expect(ProgramExit.status(forApp: 2_000_000_002, in: trail) == 7)
    }

    /// Genshin runs in a playtest closed as `exit unknown` (2026-09-26): the parent's
    /// status was in the helper's log and nowhere the record looked.
    @Test
    func `a program whose parent exited with 0 exited normally`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: program)
        try append(ProgramExit.line(genshin, status: 0), in: root)
        recorder.close(appID: program)
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .user)
        #expect(record.exit?.code == 0)
    }

    @Test
    func `a program whose parent exited with an error exited with that code`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: program)
        try append(ProgramExit.line(genshin, status: 3), in: root)
        recorder.close(appID: program)
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .exitError)
        #expect(record.exit?.code == 3)
    }

    @Test
    func `a crash in the trail is still a crash, with the code beside it`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: program)
        try append(
            "0288:0214:err:seh:NtRaiseException Unhandled exception code c0000005 flags 0 addr 0x1400\n"
                + ProgramExit.line(genshin, status: 5),
            in: root,
        )
        recorder.close(appID: program)
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .crash)
        #expect(record.exit?.code == 5)
    }

    /// The program's own process going is what closes the run, and the
    /// parent that reports its code ends a moment later.
    @Test
    func `a run closed while the parent is still ending waits for its line`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root, grace: .seconds(3))
        recorder.arm(appID: program)
        recorder.close(appID: program)
        try await Task.sleep(for: .milliseconds(400))
        #expect(RunLog.records(inMonth: .now, in: root).isEmpty)
        try append(ProgramExit.line(genshin, status: 0), in: root)
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .user)
        #expect(record.exit?.code == 0)
    }

    @Test
    func `a program with no line is recorded with no exit to name`() async throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let recorder = try makeRecorder(in: root)
        recorder.arm(appID: program)
        recorder.close(appID: program)
        let record = try #require(await records(in: root, waitingFor: 1).first)
        #expect(record.exit?.kind == .unknown)
        #expect(record.exit?.code == nil)
    }

    @Test
    func `the launcher is named by its file, however the path is spelled`() {
        #expect(ClientLifecycle.programName(of: #"C:\windows\system32\steam.exe"#) == "steam.exe")
        #expect(ClientLifecycle.programName(of: "/Users/someone/Games/HuniePop/HuniePop.exe") == "HuniePop.exe")
        #expect(ClientLifecycle.programName(of: "start") == "start")
    }
}
