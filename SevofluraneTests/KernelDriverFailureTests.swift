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
}
