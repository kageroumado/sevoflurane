import Foundation
import Testing
@testable import Sevoflurane

/// Steam's launch options as Proton fixes write them, taken apart into what
/// Sevoflurane keeps and what Steam keeps.
struct SteamLaunchCommandTests {
    private typealias Assignment = SteamLaunchCommand.Assignment

    private func parse(_ line: String) throws -> SteamLaunchCommand {
        try #require(SteamLaunchCommand.parse(line))
    }

    @Test
    func `assignments ahead of %command% leave, and Steam keeps the rest as written`() throws {
        let command = try parse("DXVK_HUD=1 PROTON_USE_WINED3D=1 %command% -windowed")
        #expect(command.assignments == [
            Assignment(name: "DXVK_HUD", value: "1"),
            Assignment(name: "PROTON_USE_WINED3D", value: "1"),
        ])
        #expect(command.wrappers.isEmpty)
        #expect(command.remainder == "%command% -windowed")
    }

    @Test
    func `a line with nothing ahead of %command%, or none at all, is Steam's`() {
        #expect(SteamLaunchCommand.parse("") == nil)
        #expect(SteamLaunchCommand.parse("   ") == nil)
        #expect(SteamLaunchCommand.parse("-windowed -novid") == nil)
        #expect(SteamLaunchCommand.parse("DXVK_HUD=1 -windowed") == nil)
        #expect(SteamLaunchCommand.parse("%command% -windowed") == nil)
        #expect(SteamLaunchCommand.parse("  %command%") == nil)
    }

    @Test
    func `quotes and escapes resolve the way a shell resolves them`() throws {
        let command = try parse(#"A="two words" B='it''s' C=a\ b D="q\"x\\y\$z" E='\n' F= %command%"#)
        #expect(command.assignments == [
            Assignment(name: "A", value: "two words"),
            Assignment(name: "B", value: "its"),
            Assignment(name: "C", value: "a b"),
            Assignment(name: "D", value: #"q"x\y$z"#),
            Assignment(name: "E", value: #"\n"#),
            Assignment(name: "F", value: ""),
        ])
        #expect(command.remainder == "%command%")
    }

    @Test
    func `a quoted name or a name no shell takes is a word, not an assignment`() throws {
        let quoted = try parse(#""A=1" %command%"#)
        #expect(quoted.assignments.isEmpty)
        #expect(quoted.wrappers == ["A=1"])
        let digit = try parse("1A=1 %command%")
        #expect(digit.assignments.isEmpty)
        #expect(digit.wrappers == ["1A=1"])
        let value = try parse("A=x=y %command%")
        #expect(value.assignments == [Assignment(name: "A", value: "x=y")])
    }

    @Test
    func `a program ahead of %command% is left out, with what follows it`() throws {
        let command = try parse("DXVK_ASYNC=1 gamemoderun mangohud B=2 %command% -dx11")
        #expect(command.assignments == [Assignment(name: "DXVK_ASYNC", value: "1")])
        #expect(command.wrappers == ["gamemoderun", "mangohud", "B=2"])
        #expect(command.remainder == "%command% -dx11")
    }

    @Test
    func `env's arguments are assignments`() throws {
        let command = try parse("env A=1 B=2 %command%")
        #expect(command.assignments.map(\.name) == ["A", "B"])
        #expect(command.wrappers.isEmpty)
    }

    @Test
    func `the first %command% splits the line; a later one stays in Steam's part`() throws {
        let command = try parse("A=1 %command% -x %command%")
        #expect(command.assignments == [Assignment(name: "A", value: "1")])
        #expect(command.remainder == "%command% -x %command%")
    }

    @Test
    func `%command% is the placeholder only as a word of its own, quoted or not`() throws {
        #expect(SteamLaunchCommand.parse("A=1 x%command%") == nil)
        let quoted = try parse(#"A=1 "%command%" -w"#)
        #expect(quoted.remainder == #""%command%" -w"#)
    }

    @Test
    func `tabs and repeated spaces separate words, and an unclosed quote runs to the end`() throws {
        let spaced = try parse("A=1\t\t B=2   %command%\t-w ")
        #expect(spaced.assignments.map(\.name) == ["A", "B"])
        #expect(spaced.remainder == "%command%\t-w")
        let open = try parse(#"A=1 %command% "-w"#)
        #expect(open.remainder == #"%command% "-w"#)
        #expect(SteamLaunchCommand.parse(#"A="1 %command%"#) == nil)
    }

    // MARK: - Applying

    @Test
    func `variables join the game's environment over what it had`() throws {
        var values = ConfigValues(environment: ["KEEP": "1", "DXVK_HUD": "0"])
        let notes = try parse("DXVK_HUD=fps WINEDLLOVERRIDES=\"d3d9=n,b\" %command%").apply(to: &values)
        #expect(values.environment == ["KEEP": "1", "DXVK_HUD": "fps", "WINEDLLOVERRIDES": "d3d9=n,b"])
        #expect(notes.count == 2)
    }

    @Test
    func `Proton's switches with a row here set that row`() throws {
        var values = ConfigValues.empty
        _ = try parse("PROTON_USE_WINED3D=1 PROTON_FORCE_LARGE_ADDRESS_AWARE=1 PROTON_LOG=1 %command%")
            .apply(to: &values)
        #expect(values.renderer == .wined3d)
        #expect(values.largeAddressAware == true)
        #expect(values.environment == ["PROTON_LOG": "1"])

        var off = ConfigValues.empty
        _ = try parse("PROTON_USE_WINED3D=0 %command%").apply(to: &off)
        #expect(off == .empty)
    }

    @Test
    func `a name the bottle needs is left out and said so`() throws {
        var values = ConfigValues.empty
        let notes = try parse("WINEPREFIX=/tmp DYLD_INSERT_LIBRARIES=x A=1 gamemoderun %command%")
            .apply(to: &values)
        #expect(values.environment == ["A": "1"])
        #expect(notes.filter { $0.contains("left out") }.count == 3)
        #expect(notes.last?.contains("gamemoderun") == true)
    }

    // MARK: - Steam's calls

    @Test
    func `only a Steam app's id names launch options`() {
        #expect(SteamLaunchCommand.appID(inArguments: ["367520", "", -1, 100]) == 367_520)
        #expect(SteamLaunchCommand.appID(inArguments: [NSNumber(value: 440), "A=1 %command%"]) == 440)
        #expect(SteamLaunchCommand.appID(inArguments: ["13836918115328278528"]) == nil)
        #expect(SteamLaunchCommand.appID(inArguments: [AdoptedPrograms.firstID]) == nil)
        #expect(SteamLaunchCommand.appID(inArguments: []) == nil)
        #expect(SteamLaunchCommand.appID(inArguments: nil) == nil)
    }

    @Test
    func `the store script quotes the line as a JavaScript string`() {
        let script = SteamLaunchCommand.storeScript(appID: 440, options: #"%command% "a\b""#)
        #expect(script.hasPrefix("SteamClient.Apps.SetAppLaunchOptions(440, "))
        #expect(script.contains(#""%command% \"a\\b\"""#))
    }
}

/// Variables set by name, from the row to the env file.
struct UserEnvironmentTests {
    @Test
    func `names follow the shell's rule`() {
        for name in ["A", "_", "DXVK_HUD", "a1_b2", "_9"] {
            #expect(UserEnvironment.isValidName(name), "\(name)")
        }
        for name in ["", "1A", "A-B", "A B", "A=B", "Ä", "A.B"] {
            #expect(!UserEnvironment.isValidName(name), "\(name)")
        }
    }

    @Test
    func `the bottle's own names, multi-line values and overlong lines are refused`() {
        #expect(UserEnvironment.problem(name: "DXVK_HUD", value: "1") == nil)
        #expect(UserEnvironment.problem(name: "DXVK_HUD", value: "") == nil)
        #expect(UserEnvironment.problem(name: "1A", value: "1") == .invalidName)
        for name in ["WINEPREFIX", "WINEMSYNC", "SEVO_LOADER", "SEVO_OWNER_PID", "DYLD_INSERT_LIBRARIES", "SEVO_NWJS_DIR"] {
            #expect(UserEnvironment.problem(name: name, value: "1") == .reserved, "\(name)")
        }
        #expect(UserEnvironment.problem(name: "A", value: "1\n2") == .invalidValue)
        #expect(UserEnvironment.problem(name: "A", value: String(repeating: "x", count: 5000)) == .tooLong)
    }

    @Test
    func `a variable a row also writes names that row`() {
        #expect(UserEnvironment.managingSetting(of: "SEVO_FPS") == SettingCatalog.setting(.fps).title)
        #expect(UserEnvironment.managingSetting(of: "WINEDLLOVERRIDES") == SettingCatalog.setting(.renderer).title)
        #expect(UserEnvironment.managingSetting(of: "DXVK_HUD") == nil)
    }

    @Test
    func `a game's variables are its file's last lines, so they win over its rows`() {
        let values = ConfigValues(environment: ["SEVO_FPS": "0", "B": ""], fps: true)
        let lines = ConfigMaterializer.gameLines(7, values)
        #expect(lines.suffix(2) == ["B=", "SEVO_FPS=0"])
        #expect(lines.contains("SEVO_FPS=1"))
        #expect(values.hasSettings)
    }

    @Test
    func `the reducer stores a variable, takes it away and refuses a bad pair`() {
        var values = ConfigValues.empty
        SettingReducer.reduce(&values, .setEnvironment(name: "A", value: "1"))
        #expect(values.environment == ["A": "1"])
        SettingReducer.reduce(&values, .setEnvironment(name: "WINEPREFIX", value: "/x"))
        SettingReducer.reduce(&values, .setEnvironment(name: "B", value: "a\nb"))
        #expect(values.environment == ["A": "1"])
        SettingReducer.reduce(&values, .setEnvironment(name: "A", value: nil))
        #expect(values.environment == nil)
        #expect(values == .empty)
    }

    @Test
    func `a shared executable's file keeps a variable only when every game sets it alike`() {
        let one = ConfigMaterializer.GameFiles(
            appID: 1, settings: ConfigMaterializer.gameLines(1, ConfigValues(environment: ["A": "1", "B": "1"])),
            exes: ["game.exe"],
        )
        let two = ConfigMaterializer.GameFiles(
            appID: 2, settings: ConfigMaterializer.gameLines(2, ConfigValues(environment: ["A": "1", "B": "2"])),
            exes: ["game.exe"],
        )
        let file = ConfigMaterializer.appFiles([one, two])["game.exe.env"] ?? []
        #expect(file.contains("A=1"))
        #expect(!file.contains { $0.hasPrefix("B=") })
    }
}
