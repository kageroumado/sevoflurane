import Foundation
import Testing
@testable import Sevoflurane

/// Telling an installer from a game from a plain program, on temporary trees
/// that carry only the signal under test.
struct ProgramDetectionTests {
    /// A directory that goes away with the test.
    private final class Tree {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appending(path: "detect-\(UUID().uuidString)")
            try FileManager.default.createDirectory(
                at: root, withIntermediateDirectories: true,
            )
        }

        deinit {
            try? FileManager.default.removeItem(at: root)
        }

        /// An empty file, which is all a sibling signal needs to be.
        @discardableResult
        func file(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try Data().write(to: url)
            return url
        }

        @discardableResult
        func directory(_ name: String) throws -> URL {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
    }

    @Test
    func `a name that says setup is an installer`() throws {
        let tree = try Tree()
        let exe = try tree.file("Setup.exe")
        #expect(ProgramDetection.classify(exe).kind == ProgramKind.installer)
    }

    @Test(arguments: ["install_me.exe", "unins000.exe", "vc_redist.x64.exe", "patch_1_02.exe"])
    func `the installer names are recognized`(name: String) throws {
        let tree = try Tree()
        let exe = try tree.file(name)
        #expect(ProgramDetection.classify(exe).kind == ProgramKind.installer)
    }

    @Test
    func `an msi beside a program makes it an installer`() throws {
        let tree = try Tree()
        try tree.file("payload.msi")
        let exe = try tree.file("start.exe")
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.installer)
        #expect(verdict.reasons.contains { $0.contains(".msi") })
    }

    @Test
    func `an installer toolkit's marker in the file is enough`() throws {
        let tree = try Tree()
        let exe = tree.root.appending(path: "start.exe")
        try Data("MZ\u{0}\u{0} ... Inno Setup ... ".utf8).write(to: exe)
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.installer)
        #expect(verdict.reasons.contains("built with Inno Setup"))
    }

    @Test
    func `Steam's API beside an exe makes it a game`() throws {
        let tree = try Tree()
        try tree.file("steam_api64.dll")
        let exe = try tree.file("Nightsong.exe")
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.game)
        #expect(verdict.reasons.contains("Steam's API beside it"))
    }

    @Test
    func `a Unity data folder makes it a game`() throws {
        let tree = try Tree()
        try tree.file("UnityPlayer.dll")
        try tree.directory("Nightsong_Data")
        let exe = try tree.file("Nightsong.exe")
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.game)
        #expect(verdict.reasons.contains("Unity beside it"))
        #expect(verdict.reasons.contains("a game data folder beside it"))
    }

    @Test
    func `a crash reporter in a game folder is not the game`() throws {
        let tree = try Tree()
        try tree.file("steam_api64.dll")
        try tree.directory("Nightsong_Data")
        let exe = try tree.file("crashreporter.exe")
        #expect(ProgramDetection.classify(exe).kind == ProgramKind.program)
    }

    @Test
    func `an exe alone in a folder is a program`() throws {
        let tree = try Tree()
        let exe = try tree.file("tool.exe")
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.program)
        #expect(verdict.reasons.isEmpty)
    }

    @Test
    func `the fixture's own version resource says installer nowhere`() {
        let fixture = URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/fixture.exe")
        #expect(ProgramDetection.classify(fixture).kind == ProgramKind.program)
    }

    /// The fixture whose manifest asks for administrator and says nothing else.
    private var adminFixture: URL {
        URL(filePath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Fixtures/admin.exe")
    }

    @Test
    func `asking for administrator alone is not an installer`() throws {
        // Genshin Impact's manifest asks for it for its anti-cheat driver; the
        // verdict used to call the game an installer and grey out Quick Launch.
        let tree = try Tree()
        let exe = tree.root.appending(path: "GenshinImpact.exe")
        try FileManager.default.copyItem(at: adminFixture, to: exe)
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.program)
        #expect(verdict.reasons.isEmpty)
    }

    @Test
    func `asking for administrator adds nothing to an installer's reasons`() throws {
        let tree = try Tree()
        try tree.file("payload.msi")
        let exe = tree.root.appending(path: "start.exe")
        try FileManager.default.copyItem(at: adminFixture, to: exe)
        let verdict = ProgramDetection.classify(exe)
        #expect(verdict.kind == ProgramKind.installer)
        #expect(verdict.reasons == ["an .msi beside it"])
    }

    @Test
    func `a file the user said is not an installer is classified without the installer signals`() throws {
        let tree = try Tree()
        try tree.file("UnityPlayer.dll")
        let exe = try tree.file("launcher_update.exe")
        #expect(ProgramDetection.classify(exe, notInstallers: []).kind == ProgramKind.installer)
        let verdict = ProgramDetection.classify(exe, notInstallers: [exe.standardizedFileURL.path])
        #expect(verdict.kind == ProgramKind.game)
    }

    @Test
    func `the verdict reads as one sentence`() throws {
        let tree = try Tree()
        try tree.file("steam_api64.dll")
        let exe = try tree.file("Nightsong.exe")
        #expect(ProgramDetection.classify(exe).summary
            == "Looks like a game: Steam's API beside it")
    }
}
