import Testing
@testable import Sevoflurane

/// Naming the kernel driver a Windows program failed to load, from Wine's log.
struct KernelDriverFailureTests {
    @Test
    func `a missing kernel import names the driver that needed it`() {
        let log = #"""
        0124:err:module:import_dll Library WDFLDR.SYS (which is needed by L"C:\\windows\\system32\\drivers\\HoYoKProtect.sys") not found
        0124:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\HoYoKProtect": c0000135
        """#
        #expect(KernelDriverFailure.driver(in: log) == "HoYoKProtect.sys")
    }

    @Test
    func `a driver service that fails to start names the driver`() {
        let log = #"0130:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\EasyAntiCheat": c0000142"#
        #expect(KernelDriverFailure.driver(in: log) == "EasyAntiCheat.sys")
    }

    @Test
    func `a missing user-mode library is not a driver failure`() {
        let log = #"0124:err:module:import_dll Library MSVCP140.dll (which is needed by L"C:\\game\\game.exe") not found"#
        #expect(KernelDriverFailure.driver(in: log) == nil)
    }

    private static let driverFailed = #"""
    sevo:run pid=4100 exe=GenshinImpact.exe appid=none engine=dormison-r17
    0124:err:ntoskrnl:ZwLoadDriver failed to create driver L"\\Driver\\HoYoKProtect": c0000135
    """#

    @Test
    func `a driver failure counts only while the program has drawn nothing`() {
        #expect(KernelDriverFailure.outcome(in: Self.driverFailed, program: "GenshinImpact.exe")
            == .driverFailed("HoYoKProtect.sys"))
        let drew = Self.driverFailed + "\nsevo:gfx pid=4100 first present +5210ms surface=0x1 layer=on-screen"
        #expect(KernelDriverFailure.outcome(in: drew, program: "genshinimpact.exe") == .presented)
    }

    @Test
    func `a frame from the game a launcher started is the program drawing`() {
        let log = Self.driverFailed + """
        
        sevo:run pid=4200 exe=Game.exe appid=none engine=dormison-r17
        sevo:gfx pid=4200 first present +900ms surface=0x2 layer=on-screen
        """
        #expect(KernelDriverFailure.outcome(in: log, program: "GenshinImpact.exe") == .presented)
    }

    @Test
    func `a frame from a Steam game or from Wine's own processes is not the program's`() {
        let log = Self.driverFailed + """
        
        sevo:run pid=4300 exe=Wukong.exe appid=2358720 engine=dormison-r17
        sevo:gfx pid=4300 first present +900ms surface=0x3 layer=on-screen
        sevo:run pid=4400 exe=explorer.exe appid=none engine=dormison-r17
        sevo:gfx pid=4400 first present +10ms surface=0x4 layer=on-screen
        """
        #expect(KernelDriverFailure.outcome(in: log, program: "GenshinImpact.exe") == .driverFailed("HoYoKProtect.sys"))
        #expect(KernelDriverFailure.outcome(in: "", program: "GenshinImpact.exe") == .nothing)
    }
}
