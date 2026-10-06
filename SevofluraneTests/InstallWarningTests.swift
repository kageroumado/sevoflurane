import Foundation
import Testing
@testable import Sevoflurane

/// The warning at Install: which games get one, and what it says.
@MainActor
struct InstallWarningTests {
    private let page = URL(string: "https://example.com/x")!

    private func wiki(native: String? = nil, crossover: String? = nil, wine: String? = nil) -> GameCompatRecord.WikiTiers {
        GameCompatRecord.WikiTiers(native: native, rosetta2: nil, crossover: crossover, wine: wine, parallels: nil, pageURL: page)
    }

    private func antiCheat(_ engines: [String], status: String) -> GameCompatRecord.AntiCheat {
        GameCompatRecord.AntiCheat(engines: engines, status: status, notes: [], sourceURL: page)
    }

    private func community(_ verdict: String) -> GameCompatRecord.Community {
        GameCompatRecord.Community(verdict: verdict, runs: 9, installs: 3, engine: nil, medianFPS: nil, pageURL: page)
    }

    private func record(
        antiCheat: GameCompatRecord.AntiCheat? = nil, wiki: GameCompatRecord.WikiTiers? = nil,
        community: GameCompatRecord.Community? = nil, hasMacBuild: Bool = false,
    ) -> GameCompatRecord {
        GameCompatRecord(
            appID: 1, name: "X", antiCheat: antiCheat, wiki: wiki, proton: nil, community: community,
            hasMacBuild: hasMacBuild, macArchitectures: nil, deckCategory: nil,
            mac: GameCompatVerdict.mac(antiCheat: antiCheat, wiki: wiki, proton: nil, community: community),
            nativeBadge: GameCompatVerdict.native(wiki: wiki, hasMacBuild: hasMacBuild),
            antiCheatBadge: GameCompatVerdict.antiCheat(antiCheat), fetchedAt: .now,
        )
    }

    @Test
    func `install risks come from anti-cheat first, then an unsupported verdict`() {
        // Kernel anti-cheat with the wiki saying the game itself runs.
        let gta = record(antiCheat: antiCheat(["BattlEye"], status: "Denied"), wiki: wiki(crossover: "perfect"))
        #expect(GameCompatVerdict.installRisk(gta) == .antiCheat(reason: gta.antiCheatBadge.reason, gameStarts: true))
        let valorant = record(antiCheat: antiCheat(["Vanguard"], status: "Denied"))
        #expect(GameCompatVerdict.installRisk(valorant) == .antiCheat(reason: valorant.antiCheatBadge.reason, gameStarts: false))
        // AreWeAntiCheatYet's Broken, for a user-mode engine.
        let broken = record(antiCheat: antiCheat(["Custom"], status: "Broken"))
        if case .antiCheat? = GameCompatVerdict.installRisk(broken) {} else { Issue.record("Broken anti-cheat warns") }
        // Sevoflurane players' runs that crash.
        let fails = record(community: community("unplayable"))
        #expect(GameCompatVerdict.installRisk(fails) == .unsupported(reason: fails.mac.reason))
        #expect(GameCompatVerdict.installRisk(record(wiki: wiki(wine: "playable"))) == nil)
        #expect(GameCompatVerdict.installRisk(record()) == nil)
        #expect(GameCompatVerdict.installRisk(record(antiCheat: antiCheat(["Custom"], status: "Supported"))) == nil)
    }

    @Test
    func `the warning names the game, the reason, and a macOS build that plays`() {
        let (title, message) = InstallWarning.text(
            for: .antiCheat(reason: "BattlEye is kernel-mode anti-cheat.", gameStarts: true), name: "PUBG", nativePlays: false,
        )
        #expect(title.contains("\u{201C}PUBG\u{201D}"))
        #expect(message.hasPrefix("BattlEye is kernel-mode anti-cheat."))
        #expect(message.contains("may start"))
        let native = InstallWarning.text(for: .unsupported(reason: "It crashes."), name: "X", nativePlays: true)
        #expect(native.message.hasPrefix("It crashes."))
        #expect(native.message.contains("Steam for Mac"))
    }
}
