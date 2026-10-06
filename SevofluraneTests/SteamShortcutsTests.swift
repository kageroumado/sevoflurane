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
    private static let nightsongTarget = SteamShortcuts.Target(
        exe: #"C:\Games\Nightsong\Nightsong.exe"#, startDir: #"C:\Games\Nightsong"#, launchOptions: "",
    )

    /// Nightsong's shortcut as Steam lists it once it starts the program.
    private static func listedNightsong(_ appid: Int = shortcut) -> SteamShortcuts.Listed {
        .init(appid: appid, exe: #""C:\Games\Nightsong\Nightsong.exe""#, startDir: #""C:\Games\Nightsong\""#)
    }

    @Test
    func `a wanted program with no shortcut gets one made`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: nil)], listed: [], owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(added: [1]))
    }

    @Test
    func `a program the user already added to Steam is claimed, not listed twice`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: nil)],
            listed: [Self.listedNightsong()],
            owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `a program keeps the shortcut its record names`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut)],
            listed: [Self.listedNightsong()],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `a shortcut the user removed in Steam turns the switch off rather than coming back`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut)],
            listed: [], owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(withdrawn: [1]))
    }

    @Test
    func `a shortcut made a moment ago is kept while Steam's list catches up`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut)],
            listed: [], owned: [Self.shortcut], fresh: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
    }

    @Test
    func `switching a program off takes its shortcut out`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: false, shortcutID: Self.shortcut)],
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
                .init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: nil),
                .init(id: 2, target: Self.nightsongTarget, wanted: true, shortcutID: nil),
            ],
            listed: [Self.listedNightsong()],
            owned: [],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut], added: [2]))
    }

    @Test
    func `a program's own shortcut is never claimed by another`() {
        let plan = SteamShortcuts.plan(
            [
                .init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: nil),
                .init(id: 2, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut),
            ],
            listed: [Self.listedNightsong()],
            owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [2: Self.shortcut], added: [1]))
    }

    @Test
    func `a kept shortcut that starts another executable is pointed at the program`() {
        let moved = SteamShortcuts.Target(
            exe: #"C:\Games\Nightsong\Launcher\Nightsong.exe"#, startDir: #"C:\Games\Nightsong\Launcher"#,
            launchOptions: "",
        )
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: moved, wanted: true, shortcutID: Self.shortcut)],
            listed: [Self.listedNightsong()], owned: [Self.shortcut],
        )
        #expect(plan == SteamShortcuts.Plan(kept: [1: Self.shortcut], retargeted: [1]))
    }

    @Test
    func `a kept shortcut with another start folder or launch options is pointed at the program`() {
        let fromRoot = SteamShortcuts.Target(
            exe: #"C:\Games\Nightsong\bin\Nightsong.exe"#, startDir: #"C:\Games\Nightsong"#, launchOptions: "-lang en",
        )
        let startsInBin = SteamShortcuts.Listed(
            appid: Self.shortcut, exe: #""C:\Games\Nightsong\bin\Nightsong.exe""#,
            startDir: #""C:\Games\Nightsong\bin\""#, launchOptions: "-lang en",
        )
        var noOptions = startsInBin
        noOptions.startDir = #""C:\Games\Nightsong\""#
        noOptions.launchOptions = ""
        for listed in [startsInBin, noOptions] {
            let plan = SteamShortcuts.plan(
                [.init(id: 1, target: fromRoot, wanted: true, shortcutID: Self.shortcut)],
                listed: [listed], owned: [Self.shortcut],
            )
            #expect(plan.retargeted == [1])
        }
    }

    @Test
    func `a shortcut made a moment ago and not yet listed is left to settle`() {
        let plan = SteamShortcuts.plan(
            [.init(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut)],
            listed: [], owned: [Self.shortcut], fresh: [Self.shortcut],
        )
        #expect(plan.retargeted.isEmpty)
    }

    @Test
    func `a shortcut carrying a store launch's program keeps it until the launch settles`() {
        let fresh = SteamShortcuts.Listed(
            appid: Self.shortcut, exe: #""C:\Games\Nightsong\Nightsong.exe""#, startDir: #""C:\Games\Nightsong\""#,
            launchOptions: "-AUTH_PASSWORD=one-time",
        )
        let program = SteamShortcuts.Program(id: 1, target: Self.nightsongTarget, wanted: true, shortcutID: Self.shortcut)
        let during = SteamShortcuts.plan([program], listed: [fresh], owned: [Self.shortcut], launching: [Self.shortcut])
        #expect(during == SteamShortcuts.Plan(kept: [1: Self.shortcut]))
        let after = SteamShortcuts.plan([program], listed: [fresh], owned: [Self.shortcut])
        #expect(after.retargeted == [1])
    }

    @Test
    func `a store launch settles once, and a late timeout leaves a newer launch alone`() {
        var launches = SteamShortcuts.Launches()
        let first = launches.begin(programID: 1, shortcut: Self.shortcut)
        #expect(launches.shortcuts == [Self.shortcut])
        #expect(launches.settle(1) == Self.shortcut)
        #expect(launches.settle(1) == nil)
        #expect(launches.shortcuts.isEmpty)

        let second = launches.begin(programID: 1, shortcut: Self.shortcut)
        #expect(launches.settle(1, generation: first) == nil)
        #expect(launches.shortcuts == [Self.shortcut])
        #expect(launches.settle(1, generation: second) == Self.shortcut)
        #expect(launches.settle(2) == nil)
    }

    @Test
    func `a program's target names its store's working folder`() {
        var program = AdoptedProgram(
            path: SteamBottle.root.appending(path: "drive_c/GOG Games/Nightsong/bin/Nightsong.exe").path,
            bottle: "Steam", kind: ProgramKind.game, addedAt: .now,
        )
        program.arguments = ["-lang", "en"]
        program.workingDirectory = SteamBottle.root.appending(path: "drive_c/GOG Games/Nightsong").path
        let target = SteamShortcuts.target(program)
        #expect(target.exe == #"C:\GOG Games\Nightsong\bin\Nightsong.exe"#)
        #expect(target.startDir == #"C:\GOG Games\Nightsong"#)
        #expect(target.launchOptions == "-lang en")
        #expect(target.quotedStartDir == #""C:\GOG Games\Nightsong\""#)

        program.workingDirectory = nil
        #expect(SteamShortcuts.target(program).startDir == #"C:\GOG Games\Nightsong\bin"#)
    }

    @Test
    func `Steam's quoted start folder and the bottle's path compare equal`() {
        #expect(SteamShortcuts.folderKey(#""C:\Games\Nightsong\""#) == SteamShortcuts.folderKey(#"c:\games\nightsong"#))
        #expect(SteamShortcuts.folderKey(#""C:\""#) == #"c:\"#)
    }

    @Test
    func `a launch from Steam names the store title behind its shortcut`() {
        let store = Self.entry(
            id: AdoptedPrograms.firstID, shortcut: Self.shortcut, store: StoreLink(store: .epic, id: "Fennec"),
        )
        let plain = Self.entry(id: AdoptedPrograms.firstID + 1, shortcut: 3_000_000_001)
        let launch = SteamShortcuts.gameID(shortcutID: Self.shortcut)
        #expect(SteamShortcuts.storeProgram(launching: launch, in: [plain, store])?.id == AdoptedPrograms.firstID)
        #expect(SteamShortcuts.storeProgram(launching: SteamShortcuts.gameID(shortcutID: 3_000_000_001), in: [plain, store]) == nil)
        #expect(SteamShortcuts.storeProgram(launching: "1245620", in: [plain, store]) == nil)
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
        let target = SteamShortcuts.Target(
            exe: #"Z:\Users\someone\fsn\bin\fsn.exe"#, startDir: #"Z:\Users\someone\fsn"#, launchOptions: "--lang ja",
        )
        let script = SteamShortcuts.addScript(name: #"Fate/stay "night""#, target: target)
        let name = JSLiteral.string(#"Fate/stay "night""#)
        let exe = JSLiteral.string(target.exe)
        #expect(script.contains("var name = \(name), exe = \(exe);"))
        #expect(script.contains(#"SteamClient.Apps.AddShortcut(name, exe, "", exe)"#))
        #expect(script.contains("SteamClient.Apps.SetShortcutName(appid, name)"))
        #expect(script.contains("SetShortcutStartDir(appid, \(JSLiteral.string(#""Z:\Users\someone\fsn\""#)))"))
        #expect(script.contains(#"SetShortcutLaunchOptions(appid, "--lang ja")"#))
    }

    @Test
    func `the retarget script sets the target, start folder and options of one shortcut`() {
        let target = SteamShortcuts.Target(
            exe: #"C:\Games\Fennec\Fennec.exe"#, startDir: #"C:\Games\Fennec"#,
            launchOptions: "-AUTH_TYPE=exchangecode -epicusername=\"someone\"",
        )
        let script = SteamShortcuts.retargetScript(Self.shortcut, target)
        #expect(script.contains("var appid = 3123456789;"))
        #expect(script.contains("SetShortcutExe(appid, \(JSLiteral.string(#""C:\Games\Fennec\Fennec.exe""#)))"))
        #expect(script.contains("SetShortcutStartDir(appid, \(JSLiteral.string(#""C:\Games\Fennec\""#)))"))
        #expect(script.contains("SetShortcutLaunchOptions(appid, \(JSLiteral.string(target.launchOptions)))"))
        #expect(script.contains(#"return "retargeted";"#))
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

    private static func entry(id: Int, shortcut: Int?, store: StoreLink? = nil) -> AdoptedPrograms.Entry {
        var program = AdoptedProgram(path: "/x.exe", bottle: "Steam", kind: ProgramKind.game, addedAt: .now)
        program.steamShortcutID = shortcut
        program.store = store
        program.inSteamLibrary = shortcut != nil
        return AdoptedPrograms.Entry(id: id, name: "X", program: program)
    }
}
