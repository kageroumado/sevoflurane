import Foundation
import Testing
@testable import Sevoflurane

/// The native supervisor's session files, and the stop that goes through it.
struct NativeSessionsTests {
    private static func file(
        appID: String = "1309000", supervisor: Int = 12345, game: Int = 12346, version: Int = 1,
    ) -> Data {
        Data("""
        {"version":\(version),"appid":"\(appID)","supervisor":\(supervisor),"game":\(game),"pgid":\(game),\
        "executable":"/Volumes/Games/SteamLibrary/steamapps/common/Game/Game.app/Contents/MacOS/Game",\
        "bundle":"/Volumes/Games/SteamLibrary/steamapps/common/Game/Game.app","started":1760112345}
        """.utf8)
    }

    @Test
    func `a session file is read as the supervisor writes it`() throws {
        let session = try #require(NativeSessions.parse(Self.file()))
        #expect(session.appID == 1_309_000)
        #expect(session.supervisor == 12345 && session.game == 12346 && session.processGroup == 12346)
        #expect(session.bundle.hasSuffix("/Game.app"))
        #expect(session.name == "game.app")
        #expect(session.started == Date(timeIntervalSince1970: 1_760_112_345))
    }

    @Test
    func `a file of another version or off the shape is no session`() {
        #expect(NativeSessions.parse(Self.file(version: 2)) == nil)
        #expect(NativeSessions.parse(Self.file(appID: "steam")) == nil)
        #expect(NativeSessions.parse(Self.file(supervisor: 0)) == nil)
        #expect(NativeSessions.parse(Data(#"{"version":1,"appid":"1"}"#.utf8)) == nil)
        #expect(NativeSessions.parse(Data("not json".utf8)) == nil)
    }

    @Test
    func `only files whose supervisor runs are live, and stale ones can be cleared`() throws {
        let bottle = FileManager.default.temporaryDirectory
            .appendingPathComponent("native-sessions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: bottle) }
        let directory = NativeSessions.directory(inBottle: bottle)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Self.file(supervisor: 100, game: 101).write(to: directory.appendingPathComponent("100.json"))
        try Self.file(supervisor: 200, game: 201).write(to: directory.appendingPathComponent("200.json"))
        // A rename not yet done, and something else entirely.
        try Self.file(supervisor: 300, game: 301).write(to: directory.appendingPathComponent(".300.json.tmp"))
        try Data("{}".utf8).write(to: directory.appendingPathComponent("400.json"))
        let machine = FakeSessionMachine(supervisors: [100, 300])

        #expect(NativeSessions.live(inBottle: bottle, machine: machine).map(\.supervisor) == [100])
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("200.json").path))
        #expect(NativeSessions.live(inBottle: bottle, machine: machine, removingStale: true).map(\.supervisor) == [100])
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("200.json").path))
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(".300.json.tmp").path))
        // No directory at all: nothing runs.
        #expect(NativeSessions.live(inBottle: bottle.appendingPathComponent("missing"), machine: machine).isEmpty)
    }

    @Test
    func `an app's processes are its supervisors, games and process groups, each once`() throws {
        let one = try #require(NativeSessions.parse(Self.file(appID: "7", supervisor: 10, game: 11)))
        let other = try #require(NativeSessions.parse(Self.file(appID: "8", supervisor: 20, game: 21)))
        let machine = FakeSessionMachine(members: [11: [11, 12, 13], 21: [21, 22]])
        #expect(NativeSessions.processes(ofApp: 7, in: [one, other], machine: machine) == [10, 11, 12, 13])
        #expect(NativeSessions.processes(ofApp: 9, in: [one, other], machine: machine).isEmpty)
    }

    @Test
    func `a stop signals the app's supervisors and answers when they have exited`() async throws {
        let one = try #require(NativeSessions.parse(Self.file(appID: "7", supervisor: 10, game: 11)))
        let other = try #require(NativeSessions.parse(Self.file(appID: "8", supervisor: 20, game: 21)))
        let machine = FakeSessionMachine(supervisors: [10, 20])
        let processes = FakeProcesses([10: .dies(on: SIGTERM, after: .seconds(2)), 20: .immortal])
        let outcome = await NativeSessions.stop(appID: 7, in: [one, other], machine: machine, processes: processes)
        #expect(outcome == NativeSessions.StopOutcome(stopped: [10]))
        #expect(processes.signals.map(\.pid) == [10])
        #expect(processes.signals.map(\.signal) == [SIGTERM])
        #expect(processes.clock == .seconds(2))
    }

    @Test
    func `a supervisor that does not exit in time is reported, never taken for stopped`() async throws {
        let one = try #require(NativeSessions.parse(Self.file(appID: "7", supervisor: 10, game: 11)))
        let processes = FakeProcesses([10: .immortal])
        let outcome = await NativeSessions.stop(
            appID: 7, in: [one], machine: FakeSessionMachine(supervisors: [10]), processes: processes,
        )
        #expect(outcome == NativeSessions.StopOutcome(survivors: [10]))
        #expect(processes.clock == NativeSessions.Constants.stopWait)
        #expect(await NativeSessions.stop(appID: 9, in: [one], processes: processes) == NativeSessions.StopOutcome())
    }

    @Test
    func `the stop summary names what the supervisors did`() {
        #expect(
            GameEnding.Outcome(sessionsStopped: [10]).summary
                == "game processes: 1 macOS build stopped through the native supervisor",
        )
        #expect(
            GameEnding.Outcome(killed: [11], sessionsUnstopped: [10]).summary
                == "game processes: 1 native supervisor ignored the stop: [10], 1 process needed SIGKILL",
        )
    }
}
