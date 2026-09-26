import Foundation
import Testing
@testable import Sevoflurane

/// The unlocker Genshin gets beside it: which programs, and what its own
/// configuration file is told.
struct FPSUnlockerTests {
    private static func program(_ path: String) -> AdoptedProgram {
        AdoptedProgram(path: path, arguments: [], bottle: "Steam", kind: ProgramKind.game, addedAt: .now)
    }

    /// An unlocker directory holding `fps_config.json` as the unlocker writes
    /// it, byte-order mark included.
    private static func unlocker(config: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fps-unlocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try (Data([0xEF, 0xBB, 0xBF]) + Data(config.utf8))
            .write(to: directory.appendingPathComponent("fps_config.json"))
        return directory.appendingPathComponent("unlockfps_nc.exe")
    }

    @Test
    func `only Genshin's two builds get it`() {
        #expect(FPSUnlocker.games.contains("genshinimpact.exe"))
        #expect(FPSUnlocker.games.contains("yuanshen.exe"))
        #expect(!FPSUnlocker.games.contains("zenlesszonezero.exe"))
        #expect(!FPSUnlocker.games.contains("starrail.exe"))
    }

    @Test
    func `the configuration names the game, the rate, and no autostart or DLLs`() throws {
        let unlocker = try Self.unlocker(config: """
        {"GamePath": "C:\\\\old.exe", "AutoStart": true, "FPSTarget": 60, "DllList": ["x.dll"], "Priority": 3}
        """)
        #expect(FPSUnlocker.configure(unlocker, game: Self.program("/Users/me/GI/GenshinImpact.exe"), target: 120))
        let written = try Data(contentsOf: unlocker.deletingLastPathComponent()
            .appendingPathComponent("fps_config.json"))
        #expect(written.starts(with: [0xEF, 0xBB, 0xBF]))
        let config = try #require(FPSUnlocker.parse(written))
        #expect(config["GamePath"] as? String == #"Z:\Users\me\GI\GenshinImpact.exe"#)
        #expect(config["FPSTarget"] as? Int == 120)
        #expect(config["AutoStart"] as? Bool == false)
        #expect((config["DllList"] as? [String])?.isEmpty == true)
        // A key this does not name is the unlocker's own and stays.
        #expect(config["Priority"] as? Int == 3)
    }

    @Test
    func `no configuration file yet is left for the unlocker to write`() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("fps-unlocker-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unlocker = directory.appendingPathComponent("unlockfps_nc.exe")
        #expect(!FPSUnlocker.configure(unlocker, game: Self.program("/GI/GenshinImpact.exe"), target: 120))
        #expect(!FileManager.default.fileExists(
            atPath: directory.appendingPathComponent("fps_config.json").path,
        ))
    }

    @Test
    func `a file without the byte-order mark reads too`() {
        #expect(FPSUnlocker.parse(Data(#"{"FPSTarget": 90}"#.utf8))?["FPSTarget"] as? Int == 90)
    }
}
