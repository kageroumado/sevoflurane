import Foundation
import Testing
@testable import Sevoflurane

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
