import Foundation
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

    /// A macOS build on an external library: its path is nowhere near the
    /// bottle, and only its session names it.
    private static func session(game: pid_t, group: pid_t, appID: Int = 892_970) -> NativeSessions.Session {
        NativeSessions.Session(
            appID: appID, supervisor: 4242, game: game, processGroup: group,
            executable: "/Volumes/Games/SteamLibrary/steamapps/common/Valheim/Valheim.app/Contents/MacOS/Valheim",
            bundle: "/Volumes/Games/SteamLibrary/steamapps/common/Valheim/Valheim.app",
            started: Date(timeIntervalSince1970: 1_760_112_345),
        )
    }

    @Test
    func `a process in a native session is that macOS build, named after its app`() throws {
        let me = getpid()
        let program = try #require(
            WineWindowWatch.resolve(owner: "Valheim", pid: me, sessions: [Self.session(game: me, group: 1)]),
        )
        #expect(program == WineWindowWatch.Program(name: "valheim.app", source: .macOSBuild, appID: 892_970))
        #expect(program.isGame)
        // The name alone, as an `.app`, is no game.
        #expect(!WineWindowWatch.isGameProgram("valheim.app"))
    }

    @Test
    func `a Mac application outside every session is not a game`() throws {
        let me = getpid()
        let other = Self.session(game: me + 100_000, group: me + 100_000)
        let program = try #require(WineWindowWatch.resolve(owner: "Discord", pid: me, sessions: [other]))
        #expect(program.source == .owner)
        #expect(!program.isGame)
        #expect(WineWindowWatch.macOSBuild(of: me, sessions: []) == nil)
    }

    @Test
    func `a child in the game's process group belongs to its session`() throws {
        let machine = FakeSessionMachine(groups: [501: 500, 502: 777])
        let session = Self.session(game: 500, group: 500)
        #expect(NativeSessions.session(owning: 500, in: [session], machine: machine) == session)
        #expect(NativeSessions.session(owning: 501, in: [session], machine: machine) == session)
        #expect(NativeSessions.session(owning: 502, in: [session], machine: machine) == nil)
        #expect(NativeSessions.session(owning: 503, in: [session], machine: machine) == nil)
    }
}

/// Process groups and supervisors as a test sets them.
struct FakeSessionMachine: NativeSessions.Machine {
    var groups: [pid_t: pid_t] = [:]
    var supervisors: Set<pid_t> = []
    var members: [pid_t: [pid_t]] = [:]

    func isSupervisor(_ pid: pid_t) -> Bool { supervisors.contains(pid) }
    func processGroup(of pid: pid_t) -> pid_t? { groups[pid] }
    func members(ofProcessGroup group: pid_t) -> [pid_t] { members[group] ?? [] }
}
