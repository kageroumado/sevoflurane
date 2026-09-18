import Foundation
import Testing
@testable import Sevoflurane

/// Which NW.js release a game is sent to. The rule that matters is the pin:
/// a game whose own series shipped only x86_64 runs on the oldest release
/// with an arm64 build rather than under Rosetta, and that release is 0.77.
struct NWJSReleaseChoiceTests {
    /// The shape of `https://nwjs.io/versions.json`, trimmed to the releases
    /// the choice turns on.
    private let index = NWJSRuntime.index(from: Data("""
    {"versions": [
      {"version": "v0.104.1", "files": ["osx-x64", "osx-arm64", "win-x64"]},
      {"version": "v0.77.0",  "files": ["osx-x64", "osx-arm64"]},
      {"version": "v0.76.1",  "files": ["osx-x64"]},
      {"version": "v0.29.4",  "files": ["osx-x64"]},
      {"version": "v0.29.3",  "files": ["osx-x64"]},
      {"version": "v0.29.0-beta1", "files": ["osx-x64", "osx-arm64"]}
    ]}
    """.utf8))

    @Test
    func `the index drops prereleases and the v`() {
        #expect(index.map(\.version) == ["0.104.1", "0.77.0", "0.76.1", "0.29.4", "0.29.3"])
    }

    @Test
    func `a game whose series has no arm64 build is pinned to 0_77`() {
        #expect(NWJSRuntime.release(
            forGameVersion: "0.29.0", in: index, flavor: "osx-arm64",
        ) == "0.77.0")
    }

    @Test
    func `on Intel the same game keeps its own series, newest patch`() {
        #expect(NWJSRuntime.release(
            forGameVersion: "0.29.0", in: index, flavor: "osx-x64",
        ) == "0.29.4")
    }

    @Test
    func `a series that does ship arm64 stays on itself`() {
        #expect(NWJSRuntime.release(
            forGameVersion: "0.77.0", in: index, flavor: "osx-arm64",
        ) == "0.77.0")
    }

    /// The folder route's only guess: NW.js names its own archives, so the
    /// unpacked directory says which release it is.
    @Test
    func `a runtime folder names its own version`() {
        func named(_ folder: String) -> String? {
            NWJSRuntime.versionName(ofFolder: URL(fileURLWithPath: "/x/\(folder)"))
        }
        #expect(named("nwjs-v0.77.0-osx-arm64") == "0.77.0")
        #expect(named("nwjs-v0.29.4-osx-x64") == "0.29.4")
        #expect(named("nwjs.app") == nil)
        #expect(named("nwjs-vsomething") == nil)
    }

    @Test
    func `an unreadable version and an index with no build here choose nothing`() {
        #expect(NWJSRuntime.release(forGameVersion: "nightly", in: index, flavor: "osx-arm64") == nil)
        #expect(NWJSRuntime.release(forGameVersion: "0.29.0", in: index, flavor: "osx-arm777") == nil)
        #expect(NWJSRuntime.index(from: Data("not json".utf8)).isEmpty)
    }
}

/// Detection against a game directory built on disk, and the warning the
/// runner switch shows before it moves a game off the bottle.
struct NWJSDetectionTests {
    private let manager = FileManager.default

    /// An RPG Maker MV layout: the loader, a package pointing at its page, and
    /// optionally greenworks and a script that calls it.
    private func makeGame(
        greenworks: Bool = false, cloudCall: String? = nil,
    ) throws -> URL {
        let root = manager.temporaryDirectory
            .appendingPathComponent("nwjs-tests-\(UUID().uuidString)")
        let www = root.appendingPathComponent("www/js")
        try manager.createDirectory(at: www, withIntermediateDirectories: true)
        try Data("loader".utf8).write(to: root.appendingPathComponent("nw.dll"))
        try Data(#"{"name": "Game", "main": "www/index.html"}"#.utf8)
            .write(to: root.appendingPathComponent("package.json"))
        try Data("<html></html>".utf8)
            .write(to: root.appendingPathComponent("www/index.html"))
        try Data("rpg".utf8).write(to: www.appendingPathComponent("rpg_core.js"))
        if greenworks {
            let modules = root.appendingPathComponent("node_modules")
            try manager.createDirectory(at: modules, withIntermediateDirectories: true)
            try Data("native".utf8)
                .write(to: modules.appendingPathComponent("greenworks-osx.node"))
        }
        if let cloudCall {
            try Data("greenworks.\(cloudCall)('save', data);".utf8)
                .write(to: www.appendingPathComponent("plugin.js"))
        }
        return root
    }

    @Test
    func `a game that only reports achievements carries no warning`() throws {
        let root = try makeGame(greenworks: true)
        defer { try? manager.removeItem(at: root) }
        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(info.flavor == "RPG Maker MV")
        #expect(info.greenworks)
        #expect(info.greenworksCloud == false)
        #expect(info.caution == nil)
        #expect(info.summary == "nwjs  · RPG Maker MV · greenworks yes")
    }

    @Test
    func `a game that saves through Steam Cloud is warned about`() throws {
        let root = try makeGame(greenworks: true, cloudCall: "saveTextToFile")
        defer { try? manager.removeItem(at: root) }
        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(info.greenworksCloud == true)
        #expect(info.caution?.contains("Steam Cloud") == true)
        #expect(info.summary.hasSuffix("(uses Steam Cloud)"))
    }

    /// A cloud call in a game with no greenworks at all is not asked about —
    /// the scan only runs for the games the bridge would have to carry.
    @Test
    func `a game with no greenworks is never scanned for cloud calls`() throws {
        let root = try makeGame(cloudCall: "saveFilesToCloud")
        defer { try? manager.removeItem(at: root) }
        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(!info.greenworks)
        #expect(info.greenworksCloud == false)
        #expect(info.caution == nil)
    }

    @Test
    func `a directory with no loader is an ordinary Windows game`() throws {
        let root = try makeGame()
        defer { try? manager.removeItem(at: root) }
        try manager.removeItem(at: root.appendingPathComponent("nw.dll"))
        #expect(NWJSGames.detect(inDirectory: root) == nil)
    }
}
