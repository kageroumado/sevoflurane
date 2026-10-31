import Foundation
import Testing
@testable import Sevoflurane

/// Whose a bottle process's window is during a launch: the engine's own
/// attribution of the process first, the exe name only without one.
struct WindowOwnershipTests {
    /// Two RPG Maker games, both shipping `game.exe`; the second is the one launching.
    private static let games: [Int: ConfigValues] = {
        var demonsRoots = ConfigValues.empty
        demonsRoots.exes = ["game.exe"]
        var other = ConfigValues.empty
        other.exes = ["game.exe", "launcher.exe"]
        return [603_750: demonsRoots, 1_234_567: other]
    }()

    private static let log = """
    0024:err:sevo:boot something unrelated
    sevo:run pid=4242 exe=Game.exe appid=1234567 engine=r8 swift=abc123 wpid=0048
    sevo:run pid=4300 exe=Game.exe appid=603750 engine=r8 swift=abc123 wpid=004c
    sevo:run pid=4400 exe=tool.exe appid=none engine=r8 swift=abc123 wpid=0050
    """

    @Test
    func `the engine's sevo:run line names a process's app, and appid=none names nothing`() {
        #expect(WineProvenance.appID(forProcess: 4242, in: Self.log) == 1_234_567)
        #expect(WineProvenance.appID(forProcess: 4300, in: Self.log) == 603_750)
        #expect(WineProvenance.appID(forProcess: 4400, in: Self.log) == nil)
        #expect(WineProvenance.appID(forProcess: 42, in: Self.log) == nil)
        // A pid reused since its first line answers its last line.
        let reused = Self.log + "\nsevo:run pid=4242 exe=Other.exe appid=603750 engine=r8 swift=abc123 wpid=0060"
        #expect(WineProvenance.appID(forProcess: 4242, in: reused) == 603_750)
    }

    @Test
    func `a process the engine attributed to the launching app owns the window, whoever recorded the exe`() {
        let ownership = GameLaunchWatch.ownership(
            ofWindowFrom: "game.exe", pid: 4242, launching: 1_234_567, attributed: 1_234_567, games: Self.games,
        )
        #expect(ownership == .launch)
    }

    @Test
    func `a process the engine attributed to another app is that app's, and the reason says so`() {
        let ownership = GameLaunchWatch.ownership(
            ofWindowFrom: "game.exe", pid: 4300, launching: 1_234_567, attributed: 603_750, games: Self.games,
        )
        guard case let .other(appID, decidedBy) = ownership else {
            Issue.record("the window was taken as the launch's")
            return
        }
        #expect(appID == 603_750)
        #expect(decidedBy.contains("engine attributed pid 4300"))
    }

    @Test
    func `without the engine's line, the launching app wins a shared exe it recorded itself`() {
        let ownership = GameLaunchWatch.ownership(
            ofWindowFrom: "game.exe", pid: 4242, launching: 1_234_567, attributed: nil, games: Self.games,
        )
        #expect(ownership == .launch)
    }

    @Test
    func `without the engine's line, an exe only another game recorded is that game's`() {
        let ownership = GameLaunchWatch.ownership(
            ofWindowFrom: "game.exe", pid: 4242, launching: 777, attributed: nil, games: Self.games,
        )
        guard case let .other(appID, decidedBy) = ownership else {
            Issue.record("the window was taken as the launch's")
            return
        }
        #expect(appID == 603_750)
        #expect(decidedBy.contains("recorded game.exe"))
        #expect(decidedBy.contains("no app id for pid 4242"))
    }

    @Test
    func `an exe nobody recorded is the launch's`() {
        let ownership = GameLaunchWatch.ownership(
            ofWindowFrom: "newgame.exe", pid: 4500, launching: 777, attributed: nil, games: Self.games,
        )
        #expect(ownership == .launch)
    }
}

/// Which of the processes the shim's chronicle names during a launch can be
/// the launch's own — the process a run record and a per-program env file
/// are named after.
struct GameLaunchWatchTests {
    /// Steam ran its system-information probe while Genshin was starting; the
    /// probe reached the driver first and the run was recorded as
    /// `steamsysinfo.exe`, 166 s (a playtest's queue).
    @Test
    func `Steam's system-information probe is never the launch's process`() throws {
        let probe = try #require(WineChronicle.parse("13:15:02.118 armed pid=61234 steamsysinfo.exe  \"\" 0x0"))
        #expect(GameLaunchWatch.launchProcess(named: probe.executable) == nil)
        let game = try #require(WineChronicle.parse("13:15:09.400 armed pid=61300 GenshinImpact.exe  \"\" 0x0"))
        #expect(GameLaunchWatch.launchProcess(named: game.executable) == "genshinimpact.exe")
    }

    @Test
    func `the client, its helpers and Wine's services are not either`() {
        for exe in ["steam.exe", "steamwebhelper.exe", "gameoverlayui64.exe", "services.exe", "wineboot.exe"] {
            #expect(GameLaunchWatch.launchProcess(named: exe) == nil, "\(exe) is not the launch's process")
        }
    }

    @Test
    func `a game's crash handler and its installers are not`() {
        for exe in ["UnityCrashHandler64.exe", "CrashReportClient.exe", "vc_redist.x64.exe", "UE4PrereqSetup_x64.exe"] {
            #expect(GameLaunchWatch.launchProcess(named: exe) == nil, "\(exe) is not the launch's process")
        }
    }
}
