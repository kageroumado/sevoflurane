import Foundation
import Testing
@testable import Sevoflurane

/// Text and names that come from a game, a download or a server, at the
/// places they reach a file, a log, a path or a request.
struct UntrustedInputTests {
    @Test
    func `a name with a line break stays one line of an env file`() {
        let hostile = "# app 7 Foo\nDYLD_INSERT_LIBRARIES=/x/y.dylib\r\nPATH=/x\u{2028}Z=1"
        let line = ConfigMaterializer.singleLine(hostile)
        #expect(line.allSatisfy { !$0.isNewline })
        #expect(line.hasPrefix("# app 7 Foo DYLD_INSERT_LIBRARIES="))
        #expect(ConfigMaterializer.singleLine("SEVO_FPS=1") == "SEVO_FPS=1")
    }

    @Test
    func `an env file's name stays inside the apps folder`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("env-\(UUID().uuidString)/apps")
        defer { try? FileManager.default.removeItem(at: dir.deletingLastPathComponent()) }
        ConfigMaterializer.writeFiles([
            "game.exe.env": ["A=1"], "folder/game.exe.env": ["A=1"],
            "../escaped.env": ["A=1"], "a/../../escaped2.env": ["A=1"], "a/b/c.env": ["A=1"],
        ], in: dir)
        let manager = FileManager.default
        #expect(manager.fileExists(atPath: dir.appendingPathComponent("game.exe.env").path))
        #expect(manager.fileExists(atPath: dir.appendingPathComponent("folder/game.exe.env").path))
        #expect(!manager.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escaped.env").path))
        #expect(!manager.fileExists(atPath: dir.deletingLastPathComponent().appendingPathComponent("escaped2.env").path))
        #expect(!manager.fileExists(atPath: dir.appendingPathComponent("a/b/c.env").path))
    }

    @Test
    func `a game that ships steam_exe gets its folder's file and never the client's`() {
        let game = ConfigMaterializer.GameFiles(
            appID: 7, settings: ["# app 7 Trojan", "SEVO_FPS=1"], exes: ["steam.exe", "game.exe"],
            loader: "SEVO_LOADER=/x", runner: ["SEVO_RUNNER=nwjs"], folder: "trojan",
        )
        let files = ConfigMaterializer.appFiles([game])
        #expect(files["steam.exe.env"] == nil)
        #expect(files["trojan/steam.exe.env"] != nil)
        #expect(files["game.exe.env"] != nil)
    }

    @Test
    func `a log entry is one line whatever it quotes`() {
        let line = EventLog.line(.bridge, "refused GET /x\n2026-01-01 00:00:00.000 [client] forged entry\r\nmore")
        #expect(line.count(where: { $0.isNewline }) == 1)
        #expect(line.hasSuffix("more\n"))
        #expect(EventLog.oneLine("plain") == "plain")
    }

    @Test
    func `only files named as the renderer names its logs are collected`() {
        #expect(GameLogs.isRendererLog("game_d3d11.log"))
        #expect(GameLogs.isRendererLog("My Game_dxgi.log"))
        #expect(!GameLogs.isRendererLog("id_ed25519"))
        #expect(!GameLogs.isRendererLog("known_hosts"))
        #expect(!GameLogs.isRendererLog("notes.txt"))
        #expect(!GameLogs.isRendererLog("config"))
    }

    @Test
    func `a device reached over the air is known by how it is attached`() {
        #expect(HostSnapshot.reportName("Ana's AirPods Pro", transport: "Bluetooth") == "Bluetooth device")
        #expect(HostSnapshot.reportName("MOONDROP Dawn Pro", transport: "USB") == "MOONDROP Dawn Pro")
        #expect(HostSnapshot.reportName(nil, transport: "built-in") == "unnamed device")
    }

    @Test
    func `run records go to the service, a developer's own over TLS, or this Mac`() {
        let service = StatsUploader.endpoint(overriddenBy: nil)
        #expect(service.host() == "kagerou.glass")
        #expect(StatsUploader.endpoint(overriddenBy: "http://evil.example/v1") == service)
        #expect(StatsUploader.endpoint(overriddenBy: "ftp://x/v1") == service)
        #expect(StatsUploader.endpoint(overriddenBy: "https://staging.example/v1").host() == "staging.example")
        #expect(StatsUploader.endpoint(overriddenBy: "http://127.0.0.1:8080/v1").port == 8080)
    }

    @Test
    func `only Steam's image hosts are fetched for a notification`() {
        #expect(SteamNotifications.isAvatarHost("avatars.steamstatic.com"))
        #expect(SteamNotifications.isAvatarHost("avatars.akamai.steamstatic.com"))
        #expect(!SteamNotifications.isAvatarHost("steamstatic.com.evil.example"))
        #expect(!SteamNotifications.isAvatarHost("evil.example"))
        #expect(!SteamNotifications.isAvatarHost(nil))
    }

    @Test
    func `a desktop alias never hides itself or replaces someone's file`() throws {
        let desktop = FileManager.default.temporaryDirectory.appendingPathComponent("desktop-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: desktop, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: desktop) }
        try Data("thesis".utf8).write(to: desktop.appendingPathComponent("Thesis"))
        #expect(DesktopShortcuts.aliasURL(named: "Thesis", in: desktop).lastPathComponent == "Thesis (Sevoflurane)")
        #expect(DesktopShortcuts.aliasURL(named: "New Game", in: desktop).lastPathComponent == "New Game")
        #expect(DesktopShortcuts.aliasURL(named: "..hidden/x:y", in: desktop).lastPathComponent == "hidden-x-y")
        #expect(DesktopShortcuts.aliasURL(named: "..", in: desktop).lastPathComponent == "Game")
    }

    @Test
    func `a build older than the one before it is noticed`() {
        let before = Preferences.highestBuildRun
        defer { Preferences.highestBuildRun = before }
        Preferences.highestBuildRun = 0
        #expect(Preferences.noteBuild(21) == nil)
        #expect(Preferences.noteBuild(22) == nil)
        #expect(Preferences.noteBuild(20) == 22)
        #expect(Preferences.highestBuildRun == 22)
    }

    @Test
    func `a run's report takes that game's settings file and no other's`() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("envs-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let mine = dir.appendingPathComponent("game.exe.env")
        let other = dir.appendingPathComponent("other.exe.env")
        try Data("# written by Sevoflurane\n# app 440 Team Fortress 2\nSEVO_FPS=1\n".utf8).write(to: mine)
        try Data("# app 4400 Something Else\n".utf8).write(to: other)
        #expect(Diagnostics.isEnvFile(mine, ofApp: 440))
        #expect(!Diagnostics.isEnvFile(mine, ofApp: 44))
        #expect(!Diagnostics.isEnvFile(other, ofApp: 440))
        #expect(Diagnostics.isEnvFile(other, ofApp: 4400))
    }
}
