import Foundation
import Testing
@testable import Sevoflurane

/// The programs that start under a `steam.exe` parent in a companion prefix,
/// and the command line and environment they start with.
struct SteamParentTests {
    private static func program(_ path: String, _ arguments: [String] = []) -> AdoptedProgram {
        AdoptedProgram(
            path: path, arguments: arguments, bottle: "Steam", kind: ProgramKind.game, addedAt: .now,
        )
    }

    @Test
    func `HoYoverse's games get the parent, whatever the case of their name`() {
        #expect(SteamParent.wants(Self.program("/Users/me/GI/GenshinImpact.exe")))
        #expect(SteamParent.wants(Self.program("/Games/YuanShen.EXE")))
        #expect(SteamParent.wants(Self.program("/Games/ZZZ/ZenlessZoneZero.exe")))
        #expect(SteamParent.wants(Self.program("/Games/Honkai/BH3.exe")))
    }

    @Test
    func `other programs, the HoYoPlay launcher among them, start in the bottle`() {
        #expect(!SteamParent.wants(Self.program("/Games/HoYoPlay/launcher.exe")))
        #expect(!SteamParent.wants(Self.program("/Games/StarRail/StarRail.exe")))
        #expect(!SteamParent.wants(Self.program("/Games/fixture.exe")))
    }

    @Test
    func `the program is named by its Z drive path behind system32's steam exe`() {
        let invocation = SteamParent.invocation(Self.program("/Users/me/GI/GenshinImpact.exe"))
        #expect(invocation == [#"C:\windows\system32\steam.exe"#, #"Z:\Users\me\GI\GenshinImpact.exe"#])
    }

    @Test
    func `each argument stays its own token`() {
        let invocation = SteamParent.invocation(
            Self.program("/Games/My Game/BH3.exe", ["-screen-fullscreen", "0", "C:/a b"]),
        )
        #expect(invocation == [
            #"C:\windows\system32\steam.exe"#, #"Z:\Games\My Game\BH3.exe"#,
            "-screen-fullscreen", "0", "C:/a b",
        ])
    }

    @Test
    func `the companion prefix is not a bottle`() {
        let companion = SteamParent.prefix(for: "Steam")
        #expect(companion.lastPathComponent == "Steam")
        #expect(!companion.path.hasPrefix(Engine.managedBottlesRoot.path + "/"))
        #expect(companion.deletingLastPathComponent().path == SteamParent.root.path)
    }

    @Test
    func `the parent sits where the game looks for it`() {
        let prefix = URL(filePath: "/tmp/companion")
        #expect(SteamParent.parentPath(in: prefix).path == "/tmp/companion/drive_c/windows/system32/steam.exe")
    }

    @Test
    func `the companion runs on the bottle's environment with only the prefix changed`() {
        let engine = Engine.managed(version: "dormison-r18")
        let bottle = engine.environment(bottle: "Steam")
        var companion = SteamParent.environment(bottle: "Steam", engine: engine)
        #expect(companion["WINEPREFIX"] == SteamParent.prefix(for: "Steam").path)
        companion["WINEPREFIX"] = bottle["WINEPREFIX"]
        #expect(companion == bottle)
    }

    @Test
    func `a CrossOver engine is refused rather than started without the parent`() async {
        let refusal = await SteamParent.prepare(bottle: "Steam", engine: .crossover)
        #expect(refusal?.contains("Dormison") == true)
    }

    @Test
    func `only DXMT's winemetal is kept in system32 without a tree copy`() {
        #expect(EngineRenderers.loaderOnlyDLLs == ["winemetal.dll"])
    }
}
