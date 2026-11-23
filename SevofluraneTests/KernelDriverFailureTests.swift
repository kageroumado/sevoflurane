import Foundation
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

    // MARK: - A splash is not the program drawing

    /// The engine's lines for a process that presents one small frame and
    /// exits, as dormison r15 writes them with the presenter on.
    private static let splashThenExit = Self.driverFailed + """
    
    sevo:presenter pid=4100 presents hooked on AGXG13XFamilyCommandBuffer
    sevo:presenter pid=4100 on: upscaler lanczos filter lanczos device Apple M1 Max
    sevo:presenter pid=4100 gl source 283x70 x4
    sevo:presenter pid=4100 chain lanczos (final filter only, 2.00×) 283x70 -> 566x140
    sevo:gfx pid=4100 renderer=d3dmetal toolkit=4.0 beta 2 presenter=on upscaler=lanczos msync=1 source=configured
    sevo:gfx pid=4100 d3d11=303b2bb4 d3d12=1b7a02cb dxgi=522a8b37
    sevo:gfx pid=4100 first present +1286ms surface=0x600001d8d810 layer=off-screen
    sevo:gfx pid=4100 exit presents=1
    """

    @Test
    func `a program that presented one frame and exited drew nothing`() {
        #expect(KernelDriverFailure.outcome(in: Self.splashThenExit, program: "GenshinImpact.exe")
            == .driverFailed("HoYoKProtect.sys"))
    }

    @Test
    func `the frames a process counted at its exit decide, whatever its surface`() {
        // With the presenter off the engine names no surface, and the count stands alone.
        let flashed = Self.driverFailed + """
        
        sevo:gfx pid=4100 first present +1286ms surface=0x1 layer=on-screen
        sevo:gfx pid=4100 exit presents=29
        """
        #expect(KernelDriverFailure.outcome(in: flashed, program: "GenshinImpact.exe") == .driverFailed("HoYoKProtect.sys"))
        let played = flashed.replacingOccurrences(of: "presents=29", with: "presents=30")
        #expect(KernelDriverFailure.outcome(in: played, program: "GenshinImpact.exe") == .presented)
        // A renderer presenting its own drawables leaves a small window's
        // surface as the only one the presenter names.
        let ownDrawables = Self.splashThenExit.replacingOccurrences(of: "presents=1", with: "presents=394907")
        #expect(KernelDriverFailure.outcome(in: ownDrawables, program: "GenshinImpact.exe") == .presented)
    }

    @Test
    func `a running process is judged by its counter page`() {
        let running = Self.driverFailed + "\nsevo:gfx pid=4100 first present +1286ms surface=0x1 layer=on-screen"
        #expect(KernelDriverFailure.outcome(in: running, program: "GenshinImpact.exe") { $0 == 4100 ? 1 : nil }
            == .driverFailed("HoYoKProtect.sys"))
        #expect(KernelDriverFailure.outcome(in: running, program: "GenshinImpact.exe") { $0 == 4100 ? 600 : nil }
            == .presented)
        // Another process's count says nothing of this one, and the frame it presented stands.
        #expect(KernelDriverFailure.outcome(in: running, program: "GenshinImpact.exe") { $0 == 9 ? 1 : nil }
            == .presented)
    }

    @Test
    func `with no count, the largest surface the presenter named decides`() {
        let splash = Self.driverFailed + """
        
        sevo:presenter pid=4100 chain lanczos (final filter only, 2.00×) 283x70 -> 566x140
        sevo:gfx pid=4100 first present +1286ms surface=0x1 layer=off-screen
        """
        #expect(KernelDriverFailure.outcome(in: splash, program: "GenshinImpact.exe") == .driverFailed("HoYoKProtect.sys"))
        // The game's own picture follows its splash.
        let thenTheGame = splash + """
        
        sevo:presenter pid=4100 source 2560x1440 80 x6
        sevo:presenter pid=4100 presents: hooked command buffer, present(afterMinimumDuration:), display sync on, source 2560x1440
        sevo:presenter pid=4100 chain lanczos (final filter only, 1.46×) 2560x1440 -> 3740x2104
        """
        #expect(KernelDriverFailure.outcome(in: thenTheGame, program: "GenshinImpact.exe") == .presented)
        // 320 by 180 is a picture; one pixel shorter or narrower is a splash.
        for (size, drew) in [("320x180", true), ("320x179", false), ("319x180", false), ("113x32", false)] {
            let log = splash.replacingOccurrences(of: "283x70 ->", with: "\(size) ->")
            #expect((KernelDriverFailure.outcome(in: log, program: "GenshinImpact.exe") == .presented) == drew, "\(size)")
        }
    }

    @Test
    func `Steam's driver probe presenting one frame is not the program drawing`() {
        // Every client boot runs gldriverquery64.exe, which starts with no app
        // id, presents one 113 by 32 frame and exits.
        let log = Self.driverFailed + """
        
        sevo:run pid=66252 exe=gldriverquery64.exe appid=none engine=dormison-r15 swift=9ac4d8f79dcf06aa wpid=0214
        sevo:presenter pid=66252 gl source 113x32 x4
        sevo:presenter pid=66252 chain lanczos (final filter only, 2.00×) 113x32 -> 226x64
        sevo:gfx pid=66252 first present +1286ms surface=0x600001d8d810 layer=off-screen
        sevo:gfx pid=66252 exit presents=1
        """
        #expect(KernelDriverFailure.outcome(in: log, program: "GenshinImpact.exe") == .driverFailed("HoYoKProtect.sys"))
    }

    @Test
    func `a counter page gives its process's frames, drawables where they are counted`() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "driver-pages-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Self.page(pid: 4100, frames: 1, drawables: 0).write(to: directory.appending(path: "4100.stats"))
        try Self.page(pid: 4200, frames: 12, drawables: 900).write(to: directory.appending(path: "4200.stats"))
        try Data("not a page".utf8).write(to: directory.appending(path: "4300.stats"))
        #expect(KernelDriverFailure.countedFrames(in: [directory]) == [4100: 1, 4200: 900])
    }

    /// One counter page as `sevo_stats.c` lays it out: the magic, frames at 8,
    /// drawables at 16, the version at 48 and the pid at 52.
    private static func page(pid: Int32, frames: UInt64, drawables: UInt64) -> Data {
        var data = Data(count: 104)
        func put(_ value: some FixedWidthInteger, at offset: Int) {
            withUnsafeBytes(of: value.littleEndian) { data.replaceSubrange(offset ..< offset + $0.count, with: $0) }
        }
        put(UInt64(0x5345_564F_5354_5331), at: 0)
        put(frames, at: 8)
        put(drawables, at: 16)
        put(UInt32(1), at: 48)
        put(UInt32(pid), at: 52)
        return data
    }
}
