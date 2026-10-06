import Foundation
import Testing
@testable import Sevoflurane

/// Adopted programs in Steam's library: the ids Steam's events carry, the
/// plan that keeps the list in step, and the scripts that change it.
struct SteamShortcutsTests {
    /// A shortcut app id as Steam makes them, high bit set.
    private static let shortcut = 3_123_456_789

    // MARK: - Ids

    @Test
    func `a launch's 64-bit game id names the shortcut in its high word`() {
        let gameID = SteamShortcuts.gameID(shortcutID: Self.shortcut)
        #expect(gameID == String(UInt64(Self.shortcut) << 32 | 0x0200_0000))
        #expect(SteamShortcuts.shortcutID(in: gameID) == Self.shortcut)
    }

    @Test
    func `a lifetime event's 32-bit app id is the shortcut itself`() {
        #expect(SteamShortcuts.shortcutID(in: String(Self.shortcut)) == Self.shortcut)
    }

    @Test
    func `a Steam game's id names no shortcut`() {
        #expect(SteamShortcuts.shortcutID(in: "1245620") == nil)
        #expect(SteamShortcuts.shortcutID(in: "") == nil)
        #expect(SteamShortcuts.shortcutID(in: "not a number") == nil)
    }

    @Test
    func `a mod's 64-bit game id names no shortcut`() {
        let mod = UInt64(Self.shortcut) << 32 | 1 << 24 | 70
        #expect(SteamShortcuts.shortcutID(in: String(mod)) == nil)
    }

    @Test
    func `an adopted program's own id is never read as a shortcut`() {
        #expect(SteamShortcuts.shortcutID(in: String(AdoptedPrograms.firstID)) == nil)
    }

    @Test
    func `the aliases map each listed program's shortcut to the program`() {
        let listed = Self.entry(id: AdoptedPrograms.firstID, shortcut: Self.shortcut)
        let unlisted = Self.entry(id: AdoptedPrograms.firstID + 1, shortcut: nil)
        #expect(SteamShortcuts.aliases([listed, unlisted]) == [Self.shortcut: AdoptedPrograms.firstID])
    }

    @Test
    func `a shortcut launch resolves to the program's own id`() {
        let aliases = [Self.shortcut: AdoptedPrograms.firstID]
        let launch = SteamShortcuts.gameID(shortcutID: Self.shortcut)
        #expect(SteamShortcuts.appID(fromSteam: launch, aliases: aliases) == AdoptedPrograms.firstID)
        #expect(SteamShortcuts.appID(fromSteam: String(Self.shortcut), aliases: aliases) == AdoptedPrograms.firstID)
        #expect(SteamShortcuts.appID(fromSteam: "1245620", aliases: aliases) == 1_245_620)
        // A shortcut that is no program's keeps the id it always had.
        #expect(SteamShortcuts.appID(fromSteam: "3000000000", aliases: aliases) == 3_000_000_000)
    }

    // MARK: - Matching

    @Test
    func `Steam's quoted target and the bottle's path compare equal`() {
        #expect(SteamShortcuts.exeKey(#""C:\Games\Nightsong\Nightsong.exe""#)
            == SteamShortcuts.exeKey(#"c:\games\nightsong\NIGHTSONG.EXE"#))
        #expect(SteamShortcuts.exeKey("Z:/Users/someone/fsn.exe") == #"z:\users\someone\fsn.exe"#)
    }

    @Test
    func `arguments become one launch-option line that splits back the same`() {
        #expect(SteamShortcuts.launchOptions([]) == "")
        #expect(SteamShortcuts.launchOptions(["--lang", "ja"]) == "--lang ja")
        #expect(SteamShortcuts.launchOptions(["--save", #"C:\My Saves\"#]) == #"--save "C:\My Saves\\""#)
        #expect(SteamShortcuts.launchOptions([#"say "hi""#]) == #""say \"hi\"""#)
        #expect(SteamShortcuts.launchOptions([""]) == #""""#)
        #expect(SteamShortcuts.launchOptions([#"C:\plain\path"#]) == #"C:\plain\path"#)
    }

    // MARK: - The plan

    private static let nightsong = #"c:\games\nightsong\nightsong.exe"#
    private static let fsn = #"z:\users\someone\fsn.exe"#

    @Test
    func `a wanted program with no shortcut gets one made`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: nil)], listed: [], owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(added: [1]))
    }

    @Test
    func `a program the user already added to Steam is claimed, not listed twice`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: nil)],
            listed: [.init(appid: Self.shortcut, exe: #""C:\Games\Nightsong\Nightsong.exe""#)],
            owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `a program keeps the shortcut its record names`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: Self.shortcut)],
            listed: [.init(appid: Self.shortcut, exe: "")],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `a shortcut the user removed in Steam turns the switch off rather than coming back`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: Self.shortcut)],
            listed: [], owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(withdrawn: [1]))
    }

    @Test
    func `a shortcut made a moment ago is kept while Steam's list catches up`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: Self.shortcut)],
            listed: [], owned: [Self.shortcut], fresh: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `switching a program off takes its shortcut out`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, exe: Self.nightsong, wanted: false, shortcutID: Self.shortcut)],
            listed: [.init(appid: Self.shortcut, exe: Self.nightsong)],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(removed: [Self.shortcut], forgotten: [1]))
    }

    @Test
    func `a removed program's shortcut goes, and the user's own shortcuts stay`() {
        let usersOwn = 3_999_999_999
        let plan = SteamShortcuts.plan(
            [],
            listed: [.init(appid: Self.shortcut, exe: Self.nightsong), .init(appid: usersOwn, exe: Self.fsn)],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(removed: [Self.shortcut]))
    }

    @Test
    func `two programs never claim one shortcut`() {
        let plan = SteamShortcuts.plan(
            [
                .init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: nil),
                .init(id: 2, exe: Self.nightsong, wanted: true, shortcutID: nil),
            ],
            listed: [.init(appid: Self.shortcut, exe: Self.nightsong)],
            owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut], added: [2]))
    }

    @Test
    func `a program's own shortcut is never claimed by another`() {
        let plan = SteamShortcuts.plan(
            [
                .init(id: 1, exe: Self.nightsong, wanted: true, shortcutID: nil),
                .init(id: 2, exe: Self.nightsong, wanted: true, shortcutID: Self.shortcut),
            ],
            listed: [.init(appid: Self.shortcut, exe: Self.nightsong)],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [2: Self.shortcut], added: [1]))
    }

    @Test
    func `the list owned by the app round-trips through the defaults`() throws {
        let defaults = try #require(UserDefaults(suiteName: "SteamShortcutsTests-\(UUID().uuidString)"))
        #expect(SteamShortcuts.owned(in: defaults).isEmpty)
        SteamShortcuts.setOwned([Self.shortcut, 3_000_000_001], in: defaults)
        #expect(SteamShortcuts.owned(in: defaults) == [Self.shortcut, 3_000_000_001])
    }

    // MARK: - Scripts

    @Test
    func `the add script makes the shortcut the way Steam's dialog does`() {
        let script = SteamShortcuts.addScript(
            name: #"Fate/stay "night""#, exe: #"Z:\Users\someone\fsn.exe"#, launchOptions: "--lang ja",
        )
        let name = JSLiteral.string(#"Fate/stay "night""#)
        let exe = JSLiteral.string(#"Z:\Users\someone\fsn.exe"#)
        #expect(script.contains("var name = \(name), exe = \(exe);"))
        #expect(script.contains(#"SteamClient.Apps.AddShortcut(name, exe, "", exe)"#))
        #expect(script.contains("SteamClient.Apps.SetShortcutName(appid, name)"))
        #expect(script.contains(#"var options = "--lang ja";"#))
    }

    @Test
    func `the remove script names every shortcut by number`() {
        #expect(SteamShortcuts.removeScript([Self.shortcut, 3_000_000_001])
            .hasPrefix("[3123456789,3000000001].forEach"))
    }

    // MARK: - The record

    @Test
    func `a record written before the switch existed still reads, unlisted`() throws {
        let json = #"{"path":"/x.exe","arguments":[],"bottle":"Steam","kind":"game","addedAt":0}"#
        let program = try JSONDecoder().decode(AdoptedProgram.self, from: Data(json.utf8))
        #expect(program.inSteamLibrary == nil)
        #expect(program.steamShortcutID == nil)
    }

    private static func entry(id: Int, shortcut: Int?) -> AdoptedPrograms.Entry {
        var program = AdoptedProgram(path: "/x.exe", bottle: "Steam", kind: ProgramKind.game, addedAt: .now)
        program.steamShortcutID = shortcut
        program.inSteamLibrary = shortcut != nil
        return AdoptedPrograms.Entry(id: id, name: "X", program: program)
    }
}
