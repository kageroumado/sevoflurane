import Foundation
import Testing
@testable import Sevoflurane

/// The settings whose sink is the prefix's registry: what the store asks for,
/// and the record that keeps a pass from spawning anything twice.
struct ConfigRegistryTests {
    private func prefix() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-registry-\(UUID().uuidString)")
    }

    @Test
    func `the record round-trips, and an unwritten prefix has none`() {
        let root = prefix()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(ConfigRegistry.record(prefix: root).isEmpty)
        let entries = [
            ConfigRegistry.Entry(key: "Mac Driver", name: "RetinaMode", value: "Y"),
            ConfigRegistry.Entry(
                key: #"AppDefaults\game.exe\DllOverrides"#, name: "xaudio2_7", value: "n,b",
            ),
        ]
        ConfigRegistry.setRecord(entries, prefix: root)
        #expect(ConfigRegistry.record(prefix: root) == entries)
    }

    @Test
    func `an entry names the key reg exe takes, and the place it holds`() {
        let entry = ConfigRegistry.Entry(
            key: #"AppDefaults\game.exe\X11 Driver"#, name: "EmulateModeset", value: "Y",
        )
        #expect(entry.path == #"HKCU\Software\Wine\AppDefaults\game.exe\X11 Driver"#)
        #expect(entry.place == #"AppDefaults\game.exe\X11 Driver\EmulateModeset"#)
        // Two values of one setting share a place, so a change is one write
        // rather than a write and a stale sibling.
        let changed = ConfigRegistry.Entry(key: entry.key, name: entry.name, value: "N")
        #expect(changed.place == entry.place)
        #expect(changed != entry)
    }

    @Test
    func `the bottle always says what both switches are`() {
        let entries = ConfigRegistry.desired(bottle: SteamBottle.name)
        let retina = try? #require(entries.first { $0.name == "RetinaMode" })
        #expect(retina?.key == "Mac Driver")
        #expect(["Y", "N"].contains(retina?.value ?? ""))
        let modeset = try? #require(entries.first { $0.name == "EmulateModeset" })
        #expect(modeset?.key == "X11 Driver")
        // Retina has no per-program rung: winemac.drv reads it with no app key.
        #expect(!entries.contains { $0.name == "RetinaMode" && $0.key.contains("AppDefaults") })
    }

    @Test
    func `a game's switches and load orders become per-program entries`() throws {
        var values = ConfigValues.empty
        values.exes = ["subnautica2-win64-shipping.exe"]
        values.emulateModeset = true
        values.dllOverrides = ["xaudio2_7": "n,b", "d3d9": ""]
        #expect(values.hasSettings)
        // The shapes the sink writes, derived the way `desired` derives them.
        let exe = try #require(values.exes?[0])
        let modeset = ConfigRegistry.Entry(
            key: #"AppDefaults\\#(exe)\X11 Driver"#, name: "EmulateModeset", value: "Y",
        )
        #expect(modeset.path.hasSuffix(#"AppDefaults\subnautica2-win64-shipping.exe\X11 Driver"#))
        let disabled = ConfigRegistry.Entry(
            key: #"AppDefaults\\#(exe)\DllOverrides"#, name: "d3d9", value: "",
        )
        #expect(disabled.value.isEmpty)
    }

    @Test
    func `an empty override table is not a setting`() {
        var values = ConfigValues.empty
        values.dllOverrides = [:]
        #expect(!values.hasSettings)
    }

    @Test
    func `nothing set anywhere leaves both switches off`() {
        #expect(GameConfig.defaults.retina == false)
        #expect(GameConfig.defaults.emulateModeset == false)
    }
}
