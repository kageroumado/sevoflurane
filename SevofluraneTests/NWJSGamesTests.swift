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

    /// The fallback runtime is filtered by the binary's own header, so an
    /// x86_64 0.29 left on disk is never picked on Apple Silicon.
    @Test
    func `a runtime binary is native only with a slice for this Mac`() throws {
        let arm64: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01]
        let x86: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01]
        // FAT_MAGIC, two entries: x86_64 then arm64, 20 bytes each.
        var fat: [UInt8] = [0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2]
        fat += [0x01, 0, 0, 0x07] + [UInt8](repeating: 0, count: 16)
        fat += [0x01, 0, 0, 0x0C] + [UInt8](repeating: 0, count: 16)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("macho-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func file(_ bytes: [UInt8], _ name: String) throws -> URL {
            let url = directory.appendingPathComponent(name)
            try Data(bytes).write(to: url)
            return url
        }
        let onARM = NWJSRuntime.nativeFlavor == "osx-arm64"
        #expect(NWJSRuntime.runsNatively(try file(arm64, "arm64")) == onARM)
        #expect(NWJSRuntime.runsNatively(try file(x86, "x86")) == !onARM)
        #expect(NWJSRuntime.runsNatively(try file(fat, "fat")))
        #expect(!NWJSRuntime.runsNatively(try file([0, 1, 2], "short")))
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

    /// OMORI's layout: the binding four folders down, beside the stock
    /// `greenworks.js` (which names `saveFilesToCloud` itself) and a plugin
    /// whose cloud wrappers nothing calls.
    @Test
    func `a binding in www_js_libs is found, and unused cloud wrappers are not a cloud game`() throws {
        let root = try makeGame()
        defer { try? manager.removeItem(at: root) }
        let libs = root.appendingPathComponent("www/js/libs")
        let plugins = root.appendingPathComponent("www/js/plugins")
        try manager.createDirectory(at: libs, withIntermediateDirectories: true)
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data("native".utf8).write(to: libs.appendingPathComponent("greenworks-win32.node"))
        try Data("greenworks.saveFilesToCloud([file_name], function() {});".utf8)
            .write(to: libs.appendingPathComponent("greenworks.js"))
        try Data("""
        var steamworks = require("./js/libs/greenworks");
        SteamManager.saveTextToCloud = function(file, contents, callback) {
            steamworks.saveTextToFile(file, contents, function() { callback(); });
        };
        SteamManager.readTextFromCloud = function(file, callback) {
            steamworks.readTextFromFile(file, function(contents) { callback(contents); });
        };
        """.utf8).write(to: plugins.appendingPathComponent("Archeia_Steamworks.js"))

        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(info.greenworks)
        #expect(info.greenworksCloud == false)

        // The same wrapper, once a script calls it, makes it a cloud game.
        try Data("SteamManager.saveTextToCloud('file1', DataManager.save());".utf8)
            .write(to: plugins.appendingPathComponent("Saves.js"))
        let calling = try #require(NWJSGames.detect(inDirectory: root))
        #expect(calling.greenworksCloud == true)
    }

    @Test
    func `a cloud call is attributed to the function it sits in`() {
        let text = """
        Store.save = function(file) { steamworks.saveTextToFile(file, '', function() {}); };
        function load(file) { steamworks.readTextFromFile(file, function(c) {}); }
        greenworks.saveFilesToCloud(['a']);
        """
        #expect(NWJSGames.cloudCallers(in: text) == ["save", "load", nil])
        #expect(NWJSGames.referenceBalance(of: "load", in: "function load(f) {}; load('x');") == 1)
        #expect(NWJSGames.referenceBalance(of: "load", in: "function load(f) {}; reload('x');") == 0)
    }

    /// Braces inside strings and comments do not close a function, so a call
    /// after one stays credited to the function it sits in, and a top-level call
    /// after a closed function stays top-level.
    @Test
    func `braces in strings and comments do not move a call between scopes`() {
        let inside = """
        Store.save = function(file) {
            var close = "}"; // a } in a comment
            /* and } here */ steamworks.saveTextToFile(file, '');
        };
        """
        #expect(NWJSGames.cloudCallers(in: inside) == ["save"])
        let after = """
        function load(file) { var open = '{'; return file; }
        steamworks.saveFilesToCloud(['a']);
        """
        #expect(NWJSGames.cloudCallers(in: after) == [nil])
    }

    /// Every way a script reaches a cloud call is a mention: bracket access
    /// and a space before the parenthesis included.
    @Test
    func `bracketed and spaced cloud calls are found`() {
        let text = """
        steamworks['saveTextToFile'](file, data);
        steamworks.readTextFromFile (file, done);
        """
        #expect(NWJSGames.cloudCallers(in: text) == [nil, nil])
    }

    /// RPG Maker hands scene methods on as handlers, never calling them by
    /// name: a wrapper bound with `.bind(this)` is a wrapper in use.
    @Test
    func `a wrapper bound as a handler makes a cloud game`() throws {
        let root = try makeGame(greenworks: true)
        defer { try? manager.removeItem(at: root) }
        let plugins = root.appendingPathComponent("www/js/plugins")
        try manager.createDirectory(at: plugins, withIntermediateDirectories: true)
        try Data("""
        Scene_Save.prototype.onSavefileOk = function() {
            steamworks.saveTextToFile('file1', DataManager.makeSaveContents(), function() {});
        };
        Scene_Save.prototype.createListWindow = function() {
            this._listWindow.setHandler('ok', this.onSavefileOk.bind(this));
        };
        """.utf8).write(to: plugins.appendingPathComponent("CloudSaves.js"))
        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(info.greenworksCloud == true)
    }

    /// Only greenworks' own module is left out of the scan: a game's script
    /// whose name starts with "Greenworks" is still the game's.
    @Test
    func `a game script named after greenworks is still scanned`() throws {
        let root = try makeGame(greenworks: true)
        defer { try? manager.removeItem(at: root) }
        try Data("steamworks.saveTextToFile('file1', data);".utf8)
            .write(to: root.appendingPathComponent("www/js/GreenworksCloudSave.js"))
        let info = try #require(NWJSGames.detect(inDirectory: root))
        #expect(info.greenworksCloud == true)
    }

    @Test
    func `a directory with no loader is an ordinary Windows game`() throws {
        let root = try makeGame()
        defer { try? manager.removeItem(at: root) }
        try manager.removeItem(at: root.appendingPathComponent("nw.dll"))
        #expect(NWJSGames.detect(inDirectory: root) == nil)
    }
}

/// Which processes a native NW.js run owns.
struct NWJSNativeProcessTests {
    @Test
    func `a native run's processes are matched by the whole wrapper path`() {
        let wrappers = "/Users/me/Library/Application Support/Sevoflurane/NWJS"
        let output = """
          10     1 /nwjs/nwjs.app/Contents/MacOS/nwjs \(wrappers)/400
          11    10 /nwjs/Helper --type=renderer \(wrappers)/400/package.nw
          20     1 /nwjs/nwjs.app/Contents/MacOS/nwjs \(wrappers)/4000
          21    20 /nwjs/Helper --type=gpu-process \(wrappers)/4000 --flag
        """
        let four = NWJSRunner.processes(inPS: output, directory: wrappers + "/400")
        #expect(four.browser == [10])
        #expect(four.helpers == [11])
        let fourThousand = NWJSRunner.processes(inPS: output, directory: wrappers + "/4000")
        #expect(fourThousand.browser == [20])
        #expect(fourThousand.helpers == [21])
    }
}

/// Which games take the native runner without being asked.
struct NWJSDefaultTests {
    private func values(runner: String? = nil, version: String = "0.88.0", cloud: Bool? = nil) -> ConfigValues {
        var values = ConfigValues.empty
        values.runner = runner
        values.nwjs = NWJSInfo(
            version: version, dir: "/games/demo", main: "/games/demo/www/index.html", flavor: "RPG Maker MV",
            greenworks: cloud != nil, greenworksCloud: cloud, packageName: "demo",
        )
        return values
    }

    @Test
    func `a detected NW_js game with no runner chosen runs natively`() {
        #expect(NWJSDefault.isCandidate(values(), enabled: true))
    }

    @Test
    func `a game sent back to the bottle stays there`() {
        #expect(!NWJSDefault.isCandidate(values(runner: GameRunner.wine), enabled: true))
    }

    @Test
    func `a game that keeps progress in Steam Cloud stays in the bottle`() {
        #expect(!NWJSDefault.isCandidate(values(cloud: true), enabled: true))
        #expect(NWJSDefault.isCandidate(values(cloud: false), enabled: true))
    }

    @Test
    func `a game whose NW_js version could not be read, an ordinary game, and automatic fixes turned off are left alone`() {
        #expect(!NWJSDefault.isCandidate(values(version: ""), enabled: true))
        #expect(!NWJSDefault.isCandidate(ConfigValues.empty, enabled: true))
        #expect(!NWJSDefault.isCandidate(values(), enabled: false))
    }
}
