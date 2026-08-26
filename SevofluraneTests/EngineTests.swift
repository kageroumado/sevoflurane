import Foundation
import Testing
@testable import Sevoflurane

struct EngineManifestTests {
    private let manifestJSON = """
    {
      "schema": 1,
      "channels": {
        "stable": {
          "version": "wine11.15-r1",
          "minAppVersion": "0.1.0",
          "url": "https://example.com/sevo-engine-r1.tar.xz",
          "sha256": "abc123",
          "sizeBytes": 600000000,
          "notes": "first release"
        }
      }
    }
    """

    @Test
    func `decodes schema 1`() throws {
        let manifest = try EngineManifest.decode(Data(manifestJSON.utf8))
        let stable = try #require(manifest.stable)
        #expect(stable.version == "wine11.15-r1")
        #expect(stable.sha256 == "abc123")
    }

    @Test
    func `rejects unknown schema`() {
        let future = manifestJSON.replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 2")
        #expect(throws: (any Error).self) {
            try EngineManifest.decode(Data(future.utf8))
        }
    }
}

struct BottleGraphicsTests {
    private let conf = """
    [Bottle]
    "WineArch" = "win64"

    [EnvironmentVariables]
    "CX_BOTTLE_CREATOR_APPID" = "com.codeweavers.c4.206"
    "WINED3DMETAL" = "1"
    "WINEMSYNC" = "1"
    "CX_GRAPHICS_BACKEND" = ""
    ;;"PROMPT" = "$p$g"
    """

    @Test
    func `reads the live bottle's shape`() {
        let vars = BottleGraphics.environmentVariables(inConf: conf)
        #expect(vars["WINED3DMETAL"] == "1")
        #expect(vars["CX_GRAPHICS_BACKEND"] == "")
        #expect(vars["PROMPT"] == nil)
    }

    @Test
    func `replaces an existing variable in place`() {
        let edited = BottleGraphics.settingVariable(
            "CX_GRAPHICS_BACKEND", to: "dxmt", inConf: conf,
        )
        let vars = BottleGraphics.environmentVariables(inConf: edited)
        #expect(vars["CX_GRAPHICS_BACKEND"] == "dxmt")
        // Everything else is untouched.
        #expect(vars["CX_BOTTLE_CREATOR_APPID"] == "com.codeweavers.c4.206")
        #expect(edited.contains(";;\"PROMPT\""))
    }

    @Test
    func `removes a variable`() {
        let edited = BottleGraphics.settingVariable("WINED3DMETAL", to: nil, inConf: conf)
        #expect(BottleGraphics.environmentVariables(inConf: edited)["WINED3DMETAL"] == nil)
    }

    @Test
    func `appends a missing variable inside the section`() {
        let edited = BottleGraphics.settingVariable("WINEDXVK", to: "1", inConf: conf)
        #expect(BottleGraphics.environmentVariables(inConf: edited)["WINEDXVK"] == "1")
    }

    @Test
    func `creates the section when the conf lacks one`() {
        let bare = "[Bottle]\n\"WineArch\" = \"win64\"\n"
        let edited = BottleGraphics.settingVariable("WINEMSYNC", to: "1", inConf: bare)
        #expect(BottleGraphics.environmentVariables(inConf: edited)["WINEMSYNC"] == "1")
    }

    @Test
    func `a new variable lands above the trailing comment`() throws {
        let edited = BottleGraphics.settingVariable("WINEDXVK", to: "1", inConf: conf)
        let lines = edited.components(separatedBy: "\n")
        let added = try #require(lines.firstIndex { $0.contains("WINEDXVK") })
        let comment = try #require(lines.firstIndex { $0.contains(";;\"PROMPT\"") })
        #expect(added < comment)
    }

    @Test
    func `writes round-trip to the same file`() {
        let toDXMT = BottleGraphics.settingVariable("CX_GRAPHICS_BACKEND", to: "dxmt", inConf: conf)
        let back = BottleGraphics.settingVariable(
            "CX_GRAPHICS_BACKEND", to: "", inConf: toDXMT,
        )
        #expect(back == conf)
    }

    @Test
    func `removing an absent variable changes nothing`() {
        #expect(BottleGraphics.settingVariable("WINEDXVK", to: nil, inConf: conf) == conf)
    }
}
