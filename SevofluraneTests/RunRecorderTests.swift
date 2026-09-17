import Foundation
import Testing
@testable import Sevoflurane

/// The run record's shape on disk, and the two logs a run's end is read from.
struct RunRecorderTests {
    private static func record(
        appid: Int = 508_440, name: String? = "Totally Accurate Battle Simulator",
    ) -> RunRecord {
        RunRecord(
            t: "2026-09-09T00:28:14Z",
            appid: appid,
            name: name,
            exe: "totallyaccuratebattlesimulator.exe",
            engine: "dormison-r4",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            d3dmetal: "4.0 beta 2",
            runtime: "unity",
            macos: "26.5.2",
            chip: "Apple M4 Max",
            durationSeconds: 2.5,
            exit: RunRecord.Exit(kind: .crash, code: 1),
            host: RunRecord.Host(thermal: "nominal", load: 3.1),
        )
    }

    @Test
    func `the record's keys are the ones the diagnostics plan names`() throws {
        let encoded = try JSONEncoder().encode(Self.record())
        let json = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any],
        )
        #expect(json["appid"] as? Int == 508_440)
        #expect(json["engine"] as? String == "dormison-r4")
        #expect(json["renderer"] as? String == "dxmt")
        #expect(json["windows"] as? String == "fixed")
        #expect(json["msync"] as? Bool == true)
        #expect(json["d3dmetal"] as? String == "4.0 beta 2")
        #expect(json["duration_s"] as? Double == 2.5)
        #expect((json["exit"] as? [String: Any])?["kind"] as? String == "crash")
        #expect((json["exit"] as? [String: Any])?["code"] as? Int == 1)
        #expect((json["host"] as? [String: Any])?["thermal"] as? String == "nominal")
        // Absent, not null: the present counter and the stall watchdog have
        // nothing to say yet, and the window never came up.
        #expect(json["fps"] == nil)
        #expect(json["stalls"] == nil)
        #expect(json["window_after_s"] == nil)
    }

    @Test
    func `a record survives a round trip through its file`() throws {
        let encoded = try JSONEncoder().encode(Self.record())
        let decoded = try JSONDecoder().decode(RunRecord.self, from: encoded)
        #expect(decoded == Self.record())
    }

    @Test
    func `the summary names the game, the engine, the length and the ending`() {
        let summary = Self.record().summary
        #expect(summary.contains("Totally Accurate Battle Simulator (508440)"))
        #expect(summary.contains("dormison-r4"))
        #expect(summary.contains("ran 3 s"))
        #expect(summary.contains("crashed — exit 1"))
    }

    @Test
    func `a record with no title is named by its app id alone`() {
        #expect(Self.record(name: nil).summary.hasPrefix("app 508440 ·"))
    }

    // MARK: - Steam's game-process log

    /// Lines as Steam writes them: doubled quotes around the command line,
    /// Windows pids nothing on this side shares.
    private static let gameProcessLog = """
    [2026-09-09 00:28:14] AppID 508440 adding PID 1400 as a tracked process \
    ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\TABS\\TotallyAccurateBattleSimulator.exe""
    [2026-09-09 00:28:14] SSGL: InternalUpdateClientGame indicates change to games list
    [2026-09-09 00:28:15] AppID 508440 adding PID 1412 as a tracked process \
    ""C:\\Program Files (x86)\\Steam\\steamapps\\common\\TABS\\UnityCrashHandler64.exe" --attach 1400"
    [2026-09-09 00:28:17] AppID 508440 no longer tracking PID 1412, exit code 0
    [2026-09-09 00:28:17] AppID 508440 no longer tracking PID 1400, exit code 1
    [2026-09-09 00:28:17] Remove 508440 from running list
    """

    @Test
    func `the exit of the recorded executable is the run's exit`() {
        let exit = SteamGameProcessLog.exit(
            forApp: 508_440,
            running: "TotallyAccurateBattleSimulator.exe",
            in: Self.gameProcessLog,
        )
        #expect(exit?.code == 1)
        #expect(exit?.executable == "totallyaccuratebattlesimulator.exe")
    }

    @Test
    func `a crash handler's own exit is never the run's`() {
        let exit = SteamGameProcessLog.exit(forApp: 508_440, running: nil, in: Self.gameProcessLog)
        #expect(exit?.code == 1)
    }

    /// Steam.exe is a Windows program and writes CRLF. Swift reads `\r\n` as
    /// one Character, so splitting on `"\n"` finds no line breaks at all in
    /// this file and the whole log reads as one line.
    @Test
    func `a log written with Windows line endings is still read line by line`() {
        let crlf = Self.gameProcessLog.replacingOccurrences(of: "\n", with: "\r\n")
        let exits = SteamGameProcessLog.exits(forApp: 508_440, in: crlf)
        #expect(exits.map(\.code) == [0, 1])
        #expect(
            SteamGameProcessLog.exit(forApp: 508_440, running: nil, in: crlf)?.code == 1,
        )
    }

    @Test
    func `another app's lines are not this app's`() {
        #expect(SteamGameProcessLog.exits(forApp: 367_520, in: Self.gameProcessLog).isEmpty)
    }

    @Test
    func `the tracked processes say what the game is built on`() {
        #expect(
            SteamGameProcessLog.runtime(forApp: 508_440, in: Self.gameProcessLog, exe: nil)
                == "unity",
        )
        #expect(
            SteamGameProcessLog.runtime(forApp: 1, in: "", exe: "b1-Win64-Shipping.exe")
                == "unreal",
        )
        #expect(SteamGameProcessLog.runtime(forApp: 1, in: "", exe: "game.exe") == nil)
    }

    // MARK: - Wine's trail

    @Test
    func `the last unhandled exception is the one that ended the process`() {
        let trail = """
        0024:err:seh:NtRaiseException Unhandled exception code c0000135 flags 0 addr 0x7b010bb9
        0024:err:seh:NtRaiseException Unhandled exception code c0000005 flags 1 addr 0x140001234
        """
        let crash = WineExceptionTrail.lastException(in: trail)
        #expect(crash?.code == "0xc0000005")
        #expect(crash?.flags == "0x1")
        #expect(crash?.address == "0x140001234")
    }

    @Test
    func `a trail with no exception yields none`() {
        #expect(WineExceptionTrail.lastException(in: "info:  MoltenVK version 1.2\n") == nil)
    }

    @Test
    func `the renderer that answered the game's own process names the run`() {
        let trail = """
        sevo:run pid=6350 exe=steamwebhelper.exe appid=none engine=dormison-r9
        sevo:gfx pid=6350 renderer=d3dmetal toolkit=4.0 beta 2 presenter=off upscaler=off msync=1
        sevo:run pid=6360 exe=HuniePop.exe appid=339800 engine=dormison-r9
        sevo:gfx pid=6360 renderer=wined3d-gl toolkit=4.0 beta 2 presenter=off upscaler=off msync=1
        sevo:gfx pid=6360 first present +74629ms surface=0x600003729730 layer=on-screen
        """
        #expect(WineProvenance.renderer(forApp: 339_800, exe: "huniepop.exe", in: trail) == "wined3d-gl")
    }

    @Test
    func `an executable with spaces in its name is still the game's own`() {
        let trail = """
        sevo:run pid=8749 exe=Aka Manto.exe appid=1130620 engine=dormison-r9
        sevo:gfx pid=8749 renderer=dxmt toolkit=none presenter=off upscaler=off msync=1
        """
        #expect(WineProvenance.renderer(forApp: 1_130_620, exe: "aka manto.exe", in: trail) == "dxmt")
    }

    @Test
    func `a helper process attributed to the app names the run when its own has no line`() {
        let trail = """
        sevo:run pid=41 exe=UnityCrashHandler64.exe appid=508440 engine=dormison-r9
        sevo:gfx pid=41 renderer=dxmt toolkit=none presenter=off upscaler=off msync=1
        sevo:run pid=42 exe=totallyaccuratebattlesimulator.exe appid=508440 engine=dormison-r9
        """
        #expect(
            WineProvenance.renderer(forApp: 508_440, exe: "totallyaccuratebattlesimulator.exe", in: trail)
                == "dxmt",
        )
        #expect(WineProvenance.renderer(forApp: 1, exe: nil, in: trail) == nil)
    }

    @Test
    func `the renderer's complaints are counted, not repeated`() {
        let trail = String(repeating: "err:   Shader not found?\n", count: 16)
            + "err:   Not supported feature: 11\nerr:   Not supported feature: 12\n"
        #expect(
            WineExceptionTrail.notes(in: trail) == [
                "Shader not found? ×16",
                "Not supported feature: 11",
                "Not supported feature: 12",
            ],
        )
    }
}
