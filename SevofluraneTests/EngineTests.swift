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
    /// with its digest and the engine it ships with, and a channel on the
    /// engine repository's release.
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
           "sha256": "5f2d8f9a1c4b6e07d3a95c18be2470fa6cd91b3e08475a26cf9d14b7e3a05c62",
           "notes": "run with dormison-r3"}
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
        #expect(manifest.components?["dxmt"]?.first?.sha256?.count == 64)
    }

    /// A component the app would download and install without checking
    /// anything but TLS.
    @Test
    func `the publish gate refuses a component without a digest`() throws {
        let unhashed = publishedJSON.replacingOccurrences(
            of: "\"sha256\": \"5f2d8f9a1c4b6e07d3a95c18be2470fa6cd91b3e08475a26cf9d14b7e3a05c62\",",
            with: "\"sha256\": null,",
        )
        let problems = try EngineManifest.decode(Data(unhashed.utf8)).problems()
        #expect(problems.contains { $0.contains("components.dxmt 0.80: sha256 is missing") })
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

/// The from-file route, against a scratch engine root: what the tarball has
/// to look like, what refuses it, and how a shipped tarball is found.
struct EngineInstallerTests {
    private let manager = FileManager.default

    /// A scratch directory holding `<version>/wine/bin/wine` and an
    /// `engine-info.json`, packed as `<version>.tar.xz` beside it.
    private func makeTarball(version: String, extraTopLevel: String? = nil) async throws -> (dir: URL, tarball: URL) {
        let dir = manager.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)")
        let tree = dir.appendingPathComponent("src/\(version)")
        try manager.createDirectory(at: tree.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try Data("wine".utf8).write(to: tree.appendingPathComponent("wine/bin/wine"))
        try Data(#"{"version":"\#(version)"}"#.utf8).write(to: tree.appendingPathComponent("engine-info.json"))
        var members = [version]
        if let extraTopLevel {
            try Data().write(to: dir.appendingPathComponent("src/\(extraTopLevel)"))
            members.append(extraTopLevel)
        }
        let tarball = dir.appendingPathComponent("\(version).tar.xz")
        let packed = await Subprocess.run(
            "/usr/bin/tar", ["-cJf", tarball.path, "-C", dir.appendingPathComponent("src").path] + members,
            capture: .combined, timeout: .seconds(60),
        )
        try #require(packed.status == 0, "\(packed.output)")
        return (dir, tarball)
    }

    @Test
    func `a tarball installs under its own name and reports it`() async throws {
        let (dir, tarball) = try await makeTarball(version: "dormison-r99")
        defer { try? manager.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Engines")
        let version = try await EngineInstaller.install(from: tarball, into: root)
        #expect(version == "dormison-r99")
        #expect(manager.fileExists(atPath: root.appendingPathComponent("dormison-r99/wine/bin/wine").path))
        #expect(manager.fileExists(atPath: root.appendingPathComponent("dormison-r99/engine-info.json").path))
    }

    @Test
    func `an installed version is never replaced`() async throws {
        let (dir, tarball) = try await makeTarball(version: "dormison-r98")
        defer { try? manager.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Engines")
        _ = try await EngineInstaller.install(from: tarball, into: root)
        await #expect(throws: (any Error).self) {
            _ = try await EngineInstaller.install(from: tarball, into: root)
        }
    }

    @Test
    func `a tarball with more than the engine at its top is refused`() async throws {
        let (dir, tarball) = try await makeTarball(version: "dormison-r97", extraTopLevel: "README")
        defer { try? manager.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Engines")
        await #expect(throws: (any Error).self) {
            _ = try await EngineInstaller.install(from: tarball, into: root)
        }
        #expect(!manager.fileExists(atPath: root.appendingPathComponent("dormison-r97").path))
    }

    @Test
    func `a signature beside the tarball that fails refuses the install`() async throws {
        let (dir, tarball) = try await makeTarball(version: "dormison-r96")
        defer { try? manager.removeItem(at: dir) }
        let root = dir.appendingPathComponent("Engines")
        // Well-formed, from a key that is not the pinned one.
        let stranger = Curve25519.Signing.PrivateKey()
        let signature = try stranger.signature(for: Data(contentsOf: tarball))
        try Data(signature.base64EncodedString().utf8).write(to: EngineSignature.signatureURL(for: tarball))
        await #expect(throws: EngineSignature.Failure.signatureInvalid("dormison-r96.tar.xz")) {
            _ = try await EngineInstaller.install(from: tarball, into: root)
        }
        try Data("not base64!".utf8).write(to: EngineSignature.signatureURL(for: tarball))
        await #expect(throws: EngineSignature.Failure.signatureMalformed) {
            _ = try await EngineInstaller.install(from: tarball, into: root)
        }
        #expect(!manager.fileExists(atPath: root.appendingPathComponent("dormison-r96").path))
    }

    /// The other half of the from-disk route: the tree `package-engine.sh`
    /// leaves behind, which is what the tarball holds unpacked.
    @Test
    func `an engine folder installs under its own name and is left where it was`() async throws {
        let (dir, _) = try await makeTarball(version: "dormison-r95")
        defer { try? manager.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("src/dormison-r95")
        let root = dir.appendingPathComponent("Engines")
        let version = try await EngineInstaller.install(from: folder, into: root)
        #expect(version == "dormison-r95")
        #expect(manager.fileExists(atPath: root.appendingPathComponent("dormison-r95/wine/bin/wine").path))
        #expect(manager.fileExists(atPath: folder.appendingPathComponent("wine/bin/wine").path))
        await #expect(throws: (any Error).self) {
            _ = try await EngineInstaller.install(from: folder, into: root)
        }
    }

    @Test
    func `a folder with no wine in it is not an engine`() async throws {
        let dir = manager.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: dir) }
        let folder = dir.appendingPathComponent("dormison-r94")
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: folder.appendingPathComponent("engine-info.json"))
        await #expect(throws: (any Error).self) {
            _ = try await EngineInstaller.install(from: folder, into: dir.appendingPathComponent("Engines"))
        }
    }

    @Test
    func `the version is the file name without its archive suffix`() {
        #expect(EngineInstaller.versionName(of: URL(fileURLWithPath: "/x/dormison-r3.tar.xz")) == "dormison-r3")
        #expect(EngineInstaller.versionName(of: URL(fileURLWithPath: "/x/dormison-r3.txz")) == "dormison-r3")
        #expect(EngineInstaller.versionName(of: URL(fileURLWithPath: "/x/dormison-r3.tar")) == "dormison-r3")
        #expect(EngineInstaller.versionName(of: URL(fileURLWithPath: "/x/dormison-r3")) == "dormison-r3")
    }

    @Test
    func `the newest shipped tarball is found beside the app or in its resources`() throws {
        let dir = manager.temporaryDirectory.appendingPathComponent("engine-tests-\(UUID().uuidString)")
        defer { try? manager.removeItem(at: dir) }
        let resources = dir.appendingPathComponent("App.app/Contents/Resources")
        try manager.createDirectory(at: resources.appendingPathComponent("Engine"), withIntermediateDirectories: true)
        let bundle = dir.appendingPathComponent("App.app")
        #expect(EngineInstaller.bundledTarball(resources: resources, beside: bundle) == nil)
        try Data().write(to: dir.appendingPathComponent("dormison-r2.tar.xz"))
        try Data().write(to: dir.appendingPathComponent("notes.tar.xz"))
        #expect(EngineInstaller.bundledTarball(resources: resources, beside: bundle)?.lastPathComponent == "dormison-r2.tar.xz")
        try Data().write(to: resources.appendingPathComponent("Engine/dormison-r10.tar.xz"))
        #expect(EngineInstaller.bundledTarball(resources: resources, beside: bundle)?.lastPathComponent == "dormison-r10.tar.xz")
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

/// How a run record names the engine that booted the client, and how that
/// name is recovered from the boot record's root path.
struct EngineRecordIdentifierTests {
    @Test
    func `the record names the engine's directory, not its display form`() {
        #expect(Engine.crossover.recordIdentifier == "crossover")
        #expect(Engine.crossoverPreview.recordIdentifier == "crossover-preview")
        #expect(Engine.managed(version: "dormison-r7").recordIdentifier == "dormison-r7")
    }

    @Test
    func `a managed boot root resolves to that version`() {
        let root = Engine.managed(version: "dormison-r7").root.path
        #expect(Engine.booted(fromRoot: root) == .managed(version: "dormison-r7"))
        // The record made from it names the managed version, not whatever the
        // active selection was later staged to.
        #expect(Engine.booted(fromRoot: root)?.recordIdentifier == "dormison-r7")
    }

    @Test
    func `a CrossOver boot root resolves to CrossOver`() {
        #expect(Engine.booted(fromRoot: Engine.crossover.root.path) == .crossover)
        #expect(Engine.booted(fromRoot: Engine.crossoverPreview.root.path) == .crossoverPreview)
        // A CrossOver-booted client recorded while a managed engine is staged
        // must still say `crossover`.
        #expect(Engine.booted(fromRoot: Engine.crossover.root.path)?.recordIdentifier == "crossover")
    }

    @Test
    func `a root that names no engine resolves to nothing`() {
        #expect(Engine.booted(fromRoot: "/Applications/Something Else.app") == nil)
        #expect(Engine.booted(fromRoot: "") == nil)
    }
}
