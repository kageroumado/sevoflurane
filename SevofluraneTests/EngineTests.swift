import CryptoKit
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
          "url": "https://example.com/dormison-r1.tar.xz",
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
        let future = manifestJSON.replacingOccurrences(of: "\"schema\": 1", with: "\"schema\": 3")
        #expect(throws: (any Error).self) {
            try EngineManifest.decode(Data(future.utf8))
        }
    }

    /// The shape `publish-engine.sh` writes: schema 2, a tested component
    /// with no hash, and a channel on the engine repository's release.
    private let publishedJSON = """
    {
      "schema": 2,
      "channels": {
        "stable": {
          "version": "dormison-r3",
          "minAppVersion": "1.0",
          "url": "https://github.com/kageroumado/dormison/releases/download/r3/dormison-r3.tar.xz",
          "sha256": "694477832c85da7bfa09793029eae182cd2aafd2bfe819c91888ec39be6e93be",
          "sizeBytes": 229890008,
          "notes": "wine 11.16; commit 07b0b312313a"
        }
      },
      "components": {
        "dxmt": [
          {"version": "0.80", "url": "https://github.com/3Shain/dxmt/releases/download/v0.80/dxmt-v0.80-builtin.tar.gz",
           "sha256": null, "notes": "run with r3"}
        ]
      }
    }
    """

    @Test
    func `the published shape decodes and passes the publish gate`() throws {
        let manifest = try EngineManifest.decode(Data(publishedJSON.utf8), verified: true)
        #expect(manifest.problems().isEmpty)
        #expect(manifest.verified)
        #expect(manifest.stable?.fromVerifiedManifest == true)
        #expect(manifest.components?["dxmt"]?.first?.sha256 == nil)
    }

    @Test
    func `a decode without verification marks every release untrusted`() throws {
        let manifest = try EngineManifest.decode(Data(publishedJSON.utf8))
        #expect(!manifest.verified)
        #expect(manifest.stable?.fromVerifiedManifest == false)
    }

    @Test
    func `the publish gate names each problem`() throws {
        let broken = publishedJSON
            .replacingOccurrences(of: "https://github.com/kageroumado/dormison", with: "http://example.com/x")
            .replacingOccurrences(of: "\"sizeBytes\": 229890008", with: "\"sizeBytes\": 0")
            .replacingOccurrences(of: "694477832c85da7bfa09793029eae182cd2aafd2bfe819c91888ec39be6e93be", with: "abc")
        let problems = try EngineManifest.decode(Data(broken.utf8)).problems()
        #expect(problems.contains { $0.contains("channels.stable.url is not a kageroumado release asset") })
        #expect(problems.contains { $0.contains("channels.stable.sha256") })
        #expect(problems.contains { $0.contains("channels.stable.sizeBytes") })
    }
}

struct EngineSignatureTests {
    @Test
    func `release assets come only from our repositories over https`() throws {
        #expect(try EngineSignature.isAllowedAssetURL(
            #require(URL(string: "https://github.com/kageroumado/dormison/releases/download/r3/dormison-r3.tar.xz")),
        ))
        #expect(try EngineSignature.isAllowedAssetURL(
            #require(URL(string: "https://github.com/kageroumado/sevoflurane/releases/download/engine/engine.json.sig")),
        ))
        #expect(try !EngineSignature.isAllowedAssetURL(
            #require(URL(string: "http://github.com/kageroumado/dormison/releases/download/r3/dormison-r3.tar.xz")),
        ))
        #expect(try !EngineSignature.isAllowedAssetURL(
            #require(URL(string: "https://github.com/someone/dormison/releases/download/r3/dormison-r3.tar.xz")),
        ))
        #expect(try !EngineSignature.isAllowedAssetURL(
            #require(URL(string: "https://github.com/kageroumado/dormison/archive/refs/tags/r3.tar.gz")),
        ))
        #expect(try !EngineSignature.isAllowedAssetURL(
            #require(URL(string: "https://evil.example@github.com/kageroumado/dormison/releases/download/r3/x")),
        ))
        #expect(try !EngineSignature.isAllowedAssetURL(#require(URL(string: "file:///tmp/dormison-r3.tar.xz"))))
    }

    @Test
    func `the signature file sits beside its asset`() throws {
        let asset = try #require(URL(string: "https://github.com/kageroumado/dormison/releases/download/r3/dormison-r3.tar.xz"))
        #expect(EngineSignature.signatureURL(for: asset).absoluteString == asset.absoluteString + ".sig")
    }

    @Test
    func `a signature over the bytes verifies, and a changed byte does not`() throws {
        let key = Curve25519.Signing.PrivateKey()
        let message = Data("{\"schema\": 2}".utf8)
        let signatureFile = try Data((key.signature(for: message).base64EncodedString() + "\n").utf8)
        try EngineSignature.verify(message, signatureFile: signatureFile, subject: "engine.json", key: key.publicKey)
        var tampered = message
        tampered[0] = UInt8(ascii: " ")
        #expect(throws: EngineSignature.Failure.signatureInvalid("engine.json")) {
            try EngineSignature.verify(tampered, signatureFile: signatureFile, subject: "engine.json", key: key.publicKey)
        }
        #expect(throws: EngineSignature.Failure.signatureMalformed) {
            try EngineSignature.verify(message, signatureFile: Data("not base64!".utf8), subject: "x", key: key.publicKey)
        }
    }

    @Test
    func `the pinned key is a usable Ed25519 public key`() throws {
        _ = try EngineSignature.pinnedKey
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

/// The engine choice as it persists in the shared suite.
struct EnginePreferenceTests {
    @Test
    func `a managed engine is stored by name`() {
        #expect(Engine.crossover.preferenceValue == "crossover")
        #expect(Engine.crossoverPreview.preferenceValue == "crossover-preview")
        // By directory name, so the Engine pane can pick one installed build
        // among several and that exact one boots.
        #expect(
            Engine.managed(version: "dormison-r2").preferenceValue
                == "managed:dormison-r2",
        )
        // Nameless is "whichever built-in engine fits" — the form a choice
        // takes before its engine is installed.
        #expect(Engine.managed(version: "").preferenceValue == "managed")
    }

    @Test
    func `crossover family shares bottle conventions`() {
        #expect(Engine.crossover.isCrossOver)
        #expect(Engine.crossoverPreview.isCrossOver)
        #expect(!Engine.managed(version: "x").isCrossOver)
    }
}
