import Testing
@testable import Sevoflurane

struct WineWindowWatchTests {
    @Test
    func `a game's own exe is a game program`() {
        #expect(WineWindowWatch.isGameProgram("subnautica2.exe"))
        #expect(WineWindowWatch.isGameProgram("game-win64-shipping.exe"))
    }

    /// Higurashi's DirectX install script ran `regsvr32` inside the launch;
    /// taken for the game, its exit cancelled the launch in Steam mid-script
    /// and every later Play ran the script again.
    @Test
    func `the tools an install script runs are not`() {
        for program in ["regsvr32.exe", "msiexec.exe", "cmd.exe", "reg.exe", "dllhost.exe", "oalinst.exe"] {
            #expect(!WineWindowWatch.isGameProgram(program), "\(program) is not a game")
        }
    }

    @Test
    func `the client's own processes are not`() {
        #expect(!WineWindowWatch.isGameProgram("steam.exe"))
        #expect(!WineWindowWatch.isGameProgram("steamwebhelper.exe"))
        #expect(!WineWindowWatch.isGameProgram("gameoverlayui.exe"))
    }

    /// Steam runs these at boot and from Help ▸ System Information; each
    /// loads the Mac driver, and one that ran during a launch was taken for
    /// the game and recorded as a 166 s run (2026-09-26).
    @Test
    func `Steam's own probes are not`() {
        for program in [
            "steamsysinfo.exe", "hardwareupdater.exe", "steamsetup.exe",
            "gldriverquery.exe", "gldriverquery64.exe",
            "vulkandriverquery.exe", "vulkandriverquery64.exe",
        ] {
            #expect(!WineWindowWatch.isGameProgram(program), "\(program) is not a game")
        }
    }

    /// These run for the whole life of the bottle and each can flash a
    /// window: taken for a game's, they hold the display awake and spend a
    /// launch's activation right on nothing.
    @Test
    func `Wine's services and Sevoflurane's own bottle programs are not`() {
        for program in [
            "services.exe", "winedevice.exe", "plugplay.exe", "svchost.exe",
            "rpcss.exe", "wineboot.exe", "winemenubuilder.exe", "start.exe",
            "rundll32.exe", "sevo-discord-bridge.exe", "sevo-steamstub.exe",
            "sevo-steamstub32.exe",
        ] {
            #expect(!WineWindowWatch.isGameProgram(program), "\(program) is not a game")
        }
    }

    @Test
    func `a Mac application is not a game program`() {
        #expect(!WineWindowWatch.isGameProgram("discord"))
        #expect(!WineWindowWatch.isGameProgram("sevoflurane"))
    }
}
