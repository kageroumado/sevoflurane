import Foundation
import Testing
@testable import Sevoflurane

/// A HoYoverse game folder: which game it is, the build its `config.ini`
/// names and the files its `pkg_version` lists.
struct HoYoInstallationTests {
    @Test
    func `a folder is the game whose executable it holds`() throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(HoYoInstallation(folder: folder) == nil)
        try Data().write(to: folder.appending(path: "ZenlessZoneZero.exe"))
        #expect(HoYoInstallation(folder: folder)?.game == .zenless)
    }

    @Test
    func `games are named by slug, biz code or name`() {
        #expect(HoYoGame.named("genshin") == .genshin)
        #expect(HoYoGame.named("HKRPG_GLOBAL") == .starRail)
        #expect(HoYoGame.named("Zenless Zone Zero") == .zenless)
        #expect(HoYoGame.named("honkai") == nil)
    }

    @Test
    func `every game but Star Rail joins Quick Launch`() {
        #expect(HoYoGame.genshin.launches)
        #expect(HoYoGame.zenless.launches)
        #expect(!HoYoGame.starRail.launches)
    }

    @Test
    func `the build is config ini's game_version`() {
        let text = "[General]\r\nchannel=1\r\ngame_version=4.6.0\r\nsub_channel=1\r\n"
        #expect(HoYoInstallation.value(of: "game_version", in: text) == "4.6.0")
        #expect(HoYoInstallation.value(of: "game_version", in: "[General]\ngame_version=\n") == nil)
    }

    @Test
    func `recording a build replaces the line and keeps the rest`() {
        let text = "[General]\r\nchannel=1\r\ngame_version=4.5.0\r\nplugin_x_version=1.0.0\r\n"
        #expect(HoYoInstallation.settingVersion("4.6.0", in: text)
            == "[General]\r\nchannel=1\r\ngame_version=4.6.0\r\nplugin_x_version=1.0.0\r\n")
    }

    @Test
    func `recording a build adds the line where there is none`() {
        #expect(HoYoInstallation.settingVersion("7.1.0", in: "[General]\nchannel=1\n")
            == "[General]\ngame_version=7.1.0\nchannel=1\n")
        #expect(HoYoInstallation.settingVersion("3.2.0", in: "") == "[General]\ngame_version=3.2.0")
    }

    @Test
    func `pkg_version lines name each file with its size and md5`() {
        let text = """
        {"remoteName": "StarRail.exe", "md5": "e7bd89e917116786bcffd6fa603db048", "fileSize": 684848}
        not json
        {"remoteName": "UnityPlayer.dll", "md5": "bac0e49165dcbd7fe1d4224d7aaf43b8", "fileSize": 38734128}
        """
        #expect(HoYoInstallation.entries(in: text) == [
            .init(remoteName: "StarRail.exe", md5: "e7bd89e917116786bcffd6fa603db048", fileSize: 684848),
            .init(remoteName: "UnityPlayer.dll", md5: "bac0e49165dcbd7fe1d4224d7aaf43b8", fileSize: 38734128),
        ])
    }

    @Test
    func `verifying names missing, resized and damaged files`() throws {
        let folder = try SophonCodecTests.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let good = Data("good".utf8), damaged = Data("damaged".utf8)
        try good.write(to: folder.appending(path: "good.dll"))
        try Data("damaged, and longer".utf8).write(to: folder.appending(path: "resized.dll"))
        try Data("damagef".utf8).write(to: folder.appending(path: "damaged.dll"))
        let lines = [
            ("good.dll", good), ("resized.dll", damaged), ("damaged.dll", damaged), ("missing.dll", good),
        ].map { name, data in
            #"{"remoteName": "\#(name)", "md5": "\#(SophonCodec.md5(data))", "fileSize": \#(data.count)}"#
        }
        try lines.joined(separator: "\n").write(to: folder.appending(path: "pkg_version"), atomically: true, encoding: .utf8)
        let installation = HoYoInstallation(game: .genshin, folder: folder)
        #expect(installation.verify() == [
            .init(path: "resized.dll", kind: .size),
            .init(path: "damaged.dll", kind: .checksum),
            .init(path: "missing.dll", kind: .missing),
        ])
        #expect(installation.verify(quick: true).map(\.path) == ["resized.dll", "missing.dll"])
    }
}
