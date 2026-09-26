import Foundation
import JavaScriptCore
import Testing
@testable import Sevoflurane

/// Steam's launch-option list as the client sends it, and the memory Steam
/// keeps of an answer.
struct LaunchOptionsTests {
    private let wukong = """
    [{"nIndex":0,"strDescription":"Play","eType":0},\
    {"nIndex":1,"strDescription":"Run Benchmark Tool (Compatibility Mode)","eType":9}]
    """

    @Test
    func `the options come back in index order with their labels`() {
        let options = LaunchOptions.parse(
            "[{\"nIndex\":1,\"strDescription\":\"Run Benchmark Tool (Compatibility Mode)\",\"eType\":9},"
                + "{\"nIndex\":0,\"strDescription\":\"Play\",\"eType\":0}]",
        )
        #expect(options == [
            LaunchOption(index: 0, description: "Play", type: 0),
            LaunchOption(index: 1, description: "Run Benchmark Tool (Compatibility Mode)", type: 9),
        ])
        #expect(LaunchOptions.summary(options) == "“Play”, “Run Benchmark Tool (Compatibility Mode)”")
    }

    @Test
    func `a localization token reads as words`() {
        let options = LaunchOptions.parse("[{\"nIndex\":0,\"strDescription\":\"#LaunchOption_Play_Safe_Mode\",\"eType\":0}]")
        #expect(options.first?.description == "Play Safe Mode")
        #expect(LaunchOptions.label("#Play") == "Play")
    }

    private let megabonk = """
    [{"nIndex":0,"strDescription":"#Steam_LaunchOption_Game","eType":10,"strGameName":"Megabonk"},\
    {"nIndex":2,"strDescription":"#Steam_LaunchOption_Game","eType":11,"strGameName":"Megabonk"}]
    """

    @Test
    func `a token takes the option's own description from the app's cache`() {
        var read = 0
        let options = LaunchOptions.parse(megabonk) {
            read += 1
            return [0: "Megabonk (DX11 - Recommended)", 2: "Megabonk (DX12 - Use only if game crashes)"]
        }
        #expect(options.map(\.description) == [
            "Megabonk (DX11 - Recommended)", "Megabonk (DX12 - Use only if game crashes)",
        ])
        #expect(read == 1)
        _ = LaunchOptions.parse(wukong) {
            read += 1
            return [:]
        }
        #expect(read == 1)
    }

    @Test
    func `Steam's own play token names the game, and repeated labels carry their number`() {
        let options = LaunchOptions.parse(megabonk)
        #expect(options == [
            LaunchOption(index: 0, description: "Play Megabonk (option 1)", type: 10),
            LaunchOption(index: 2, description: "Play Megabonk (option 2)", type: 11),
        ])
        #expect(LaunchOptions.label("#Steam_LaunchOption_Game") == "Play")
        #expect(LaunchOptions.label("#Steam_LaunchOption_Editor") == "Editor")
    }

    @Test
    func `launch descriptions are read from a version 29 appinfo file`() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("appinfo-\(UUID().uuidString).vdf")
        defer { try? FileManager.default.removeItem(at: url) }
        try AppInfoFixture.megabonk().write(to: url)
        #expect(SteamAppInfo.launchDescriptions(appID: 3_405_340, in: url) == [
            0: "Megabonk (DX11 - Recommended)", 2: "Megabonk (DX12 - Use only if game crashes)",
        ])
        #expect(SteamAppInfo.launchDescriptions(appID: 1, in: url) == [:])
        #expect(SteamAppInfo.launchDescriptions(appID: 3_405_340, in: url.appendingPathExtension("missing")) == [:])
    }

    @Test
    func `malformed JSON and unnumbered entries are nothing`() {
        #expect(LaunchOptions.parse("not json") == [])
        #expect(LaunchOptions.parse("{\"nIndex\":0}") == [])
        let options = LaunchOptions.parse("[{\"strDescription\":\"Play\"},{\"nIndex\":2,\"strDescription\":\"Editor\"}]")
        #expect(options == [LaunchOption(index: 2, description: "Editor", type: 0)])
    }

    @Test
    func `a remembered answer counts only while it names an option`() {
        let options = LaunchOptions.parse(wukong)
        #expect(LaunchOptions.rememberedIndex("1", among: options) == 1)
        #expect(LaunchOptions.rememberedIndex("", among: options) == nil)
        #expect(LaunchOptions.rememberedIndex("7", among: options) == nil)
        #expect(LaunchOptions.rememberedIndex(nil, among: options) == nil)
    }

    /// Steam's key is `Apps\<appid>\DefaultLaunchOption\<hex>` where hex is the
    /// unsigned `h = h * 31 + c` hash of the options' JSON. The Swift and the
    /// JavaScript spellings must agree, since one reads what the other clears.
    @Test
    func `the remembered key is the same in Swift and in the script`() throws {
        let key = LaunchOptions.rememberedKey(appID: 2358720, optionsJSON: "[]")
        // "[]" hashes to 91 * 31 + 93 = 2914.
        #expect(key == "Apps\\2358720\\DefaultLaunchOption\\b62")
        let context = try #require(JSContext())
        let function = try #require(context.evaluateScript(LaunchOptions.rememberedKeyScript))
        let options = try #require(context.evaluateScript(wukong))
        let fromScript = try #require(function.call(withArguments: [2358720, options])?.toString())
        #expect(fromScript == LaunchOptions.rememberedKey(appID: 2358720, optionsJSON: wukong))
        #expect(fromScript.hasPrefix("Apps\\2358720\\DefaultLaunchOption\\"))
    }

    @Test
    func `the answers name the action and the option as strings`() {
        #expect(LaunchOptions.continueScript(actionID: 12, index: 1) == "SteamClient.Apps.ContinueGameAction(12, \"1\"); \"sent\"")
        #expect(LaunchOptions.cancelScript(actionID: 12) == "SteamClient.Apps.CancelGameAction(12); \"sent\"")
    }
}

/// A version 29 `appinfo.vdf` holding one unrelated app and Megabonk, whose
/// launch section is the one on a real client: two Windows options with
/// descriptions and a Linux default without one.
private enum AppInfoFixture {
    static func megabonk() -> Data {
        var strings: [String] = []
        func key(_ name: String) -> UInt32 {
            if let index = strings.firstIndex(of: name) { return UInt32(index) }
            strings.append(name)
            return UInt32(strings.count - 1)
        }
        func table(_ name: String, _ body: Data) -> Data {
            Data([0]) + le(key(name)) + body + Data([8])
        }
        func string(_ name: String, _ value: String) -> Data {
            Data([1]) + le(key(name)) + Data(value.utf8) + Data([0])
        }
        func entry(_ appID: UInt32, _ values: Data) -> Data {
            let body = Data(count: 4 + 4 + 8 + 20 + 4 + 20) + values
            return le(appID) + le(UInt32(body.count)) + body
        }
        let launch = table(
            "launch",
            table(
                "0",
                string("executable", "Megabonk.exe") + string("type", "option1")
                    + string("description", "Megabonk (DX11 - Recommended)"),
            )
                + table("1", string("executable", "Megabonk.x86_64") + string("type", "default"))
                + table(
                    "2",
                    string("executable", "Megabonk.exe") + string("type", "option2")
                        + string("description", "Megabonk (DX12 - Use only if game crashes)"),
                ),
        )
        let apps = entry(10, table("appinfo", table("common", string("name", "Counter-Strike"))) + Data([8]))
            + entry(3_405_340, table("appinfo", table("config", launch)) + Data([8]))
            + le(UInt32(0))
        let header = le(UInt32(0x0756_4429)) + le(UInt32(1))
        let tableOffset = UInt64(header.count + 8 + apps.count)
        var table = le(UInt32(strings.count))
        for name in strings { table += Data(name.utf8) + Data([0]) }
        return header + le(tableOffset) + apps + table
    }

    private static func le(_ value: some FixedWidthInteger) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }
}
