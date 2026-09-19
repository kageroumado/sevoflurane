import Testing
@testable import Sevoflurane

struct WineWindowWatchTests {
    @Test
    func `a game's own exe is a game program`() {
        #expect(WineWindowWatch.isGameProgram("subnautica2.exe"))
        #expect(WineWindowWatch.isGameProgram("game-win64-shipping.exe"))
    }

    @Test
    func `the client's own processes are not`() {
        #expect(!WineWindowWatch.isGameProgram("steam.exe"))
        #expect(!WineWindowWatch.isGameProgram("steamwebhelper.exe"))
        #expect(!WineWindowWatch.isGameProgram("gameoverlayui.exe"))
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
