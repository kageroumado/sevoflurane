import Foundation
import Testing
@testable import Sevoflurane

/// The switches that reach a game as one environment variable each.
struct ConfigSwitchTests {
    @Test
    func `the bottle names every switch, both ways`() {
        let lines = ConfigMaterializer.bottleLines(SteamBottle.name)
        for key in [
            "MTL_HUD_ENABLED", "SEVO_LARGE_ADDRESS_AWARE",
            "ROSETTA_ADVERTISE_AVX", "SEVO_CURSOR_CONFINE", "SEVO_FORCE_UMA", "SEVO_MENU_BAR",
        ] {
            let line = lines.first { $0.hasPrefix("\(key)=") }
            #expect(["\(key)=0", "\(key)=1"].contains(line ?? ""))
        }
    }

    @Test
    func `a game writes the switches it sets and leaves the rest standing`() {
        var values = ConfigValues.empty
        values.hud = true
        values.avx = false
        let lines = ConfigMaterializer.gameLines(440, values)
        #expect(lines.contains("MTL_HUD_ENABLED=1"))
        // Off is written, not omitted: the bottle's file is read first and an
        // absent key leaves its value standing.
        #expect(lines.contains("ROSETTA_ADVERTISE_AVX=0"))
        #expect(!lines.contains { $0.hasPrefix("SEVO_CURSOR_CONFINE") })
        #expect(!lines.contains { $0.hasPrefix("SEVO_LARGE_ADDRESS_AWARE") })
    }

    @Test
    func `each switch is a setting on its own`() {
        for change in [
            { (v: inout ConfigValues) in v.hud = false },
            { (v: inout ConfigValues) in v.largeAddressAware = false },
            { (v: inout ConfigValues) in v.avx = true },
            { (v: inout ConfigValues) in v.cursorConfine = true },
            { (v: inout ConfigValues) in v.unifiedMemory = true },
            { (v: inout ConfigValues) in v.nativeMenuBar = true },
        ] {
            var values = ConfigValues.empty
            change(&values)
            #expect(values.hasSettings)
        }
    }

    @Test
    func `the defaults advertise AVX and the full address space, and draw no HUD`() {
        #expect(GameConfig.defaults.avx == true)
        #expect(GameConfig.defaults.largeAddressAware == true)
        #expect(GameConfig.defaults.hud == false)
        #expect(GameConfig.defaults.cursorConfine == false)
        #expect(GameConfig.defaults.nativeMenuBar == false)
        // Unified memory is the experiment, so nothing has it until it is asked for.
        #expect(GameConfig.defaults.unifiedMemory == false)
        // The bottle has advertised AVX to every game since the translation
        // defaults were written; the hierarchy's default says the same thing.
        #expect(BottleGraphics.translationDefaults["ROSETTA_ADVERTISE_AVX"] == "1")
    }

    @Test
    func `a game asking for unified memory says so to the engine`() {
        var values = ConfigValues.empty
        values.unifiedMemory = true
        #expect(ConfigMaterializer.gameLines(1_962_700, values).contains("SEVO_FORCE_UMA=1"))
        values.unifiedMemory = false
        #expect(ConfigMaterializer.gameLines(1_962_700, values).contains("SEVO_FORCE_UMA=0"))
    }

    @Test
    func `the switches survive the round trip`() throws {
        var values = ConfigValues.empty
        values.hud = true
        values.cursorConfine = true
        values.avx = false
        values.largeAddressAware = false
        let back = try JSONDecoder().decode(
            ConfigValues.self, from: JSONEncoder().encode(values),
        )
        #expect(back == values)
    }
}
