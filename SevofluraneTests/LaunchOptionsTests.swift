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
