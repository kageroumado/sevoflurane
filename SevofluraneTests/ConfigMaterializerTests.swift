import Foundation
import Synchronization
import Testing
@testable import Sevoflurane

/// How the per-executable env files are laid out, and how passes over one
/// prefix share the work.
struct ConfigMaterializerTests {
    private static let rpgMakerA = ConfigMaterializer.GameFiles(
        appID: 400,
        settings: ["# app 400 First", "SEVO_FPS=1", "SEVO_UPSCALER=fsr"],
        exes: ["game.exe", "first.exe"],
        loader: "SEVO_LOADER=/launchers/400.app",
        runner: ["SEVO_NWJS_DIR=/nwjs/400", "SEVO_RUNNER=nwjs"],
    )
    private static let rpgMakerB = ConfigMaterializer.GameFiles(
        appID: 4000,
        settings: ["# app 4000 Second", "SEVO_FPS=1"],
        exes: ["game.exe"],
        loader: "SEVO_LOADER=/launchers/4000.app",
    )

    @Test
    func `an exe two games ship carries neither game's identity nor runner`() throws {
        let files = ConfigMaterializer.appFiles([Self.rpgMakerA, Self.rpgMakerB])

        let shared = try #require(files["game.exe.env"])
        #expect(!shared.contains { $0.hasPrefix("SEVO_LOADER=") })
        #expect(!shared.contains { $0.hasPrefix("SEVO_RUNNER=") || $0.hasPrefix("SEVO_NWJS_DIR=") })
        // What both games set alike still reaches the exe.
        #expect(shared.contains("SEVO_FPS=1"))
        #expect(!shared.contains("SEVO_UPSCALER=fsr"))

        let own = try #require(files["first.exe.env"])
        #expect(own.contains("SEVO_LOADER=/launchers/400.app"))
        #expect(own.contains("SEVO_RUNNER=nwjs"))
        #expect(own.contains("SEVO_UPSCALER=fsr"))
    }

    @Test
    func `the files are the same whatever order the games come in`() {
        let forward = ConfigMaterializer.appFiles([Self.rpgMakerA, Self.rpgMakerB])
        let backward = ConfigMaterializer.appFiles([Self.rpgMakerB, Self.rpgMakerA])
        #expect(forward == backward)
        #expect(ConfigMaterializer.sharedExecutables([Self.rpgMakerB, Self.rpgMakerA]).map(\.appIDs)
            == [[400, 4000]])
    }

    @Test
    func `a shared exe carries the full lines of the game whose launch is in flight`() throws {
        let files = ConfigMaterializer.appFiles([Self.rpgMakerA, Self.rpgMakerB], launching: 4000)
        let shared = try #require(files["game.exe.env"])
        #expect(shared.first == "# apps 400, 4000 all ship game.exe; written for app 4000's launch")
        #expect(shared.contains("# app 4000 Second"))
        #expect(shared.contains("SEVO_LOADER=/launchers/4000.app"))
        #expect(!shared.contains("SEVO_LOADER=/launchers/400.app"))
        #expect(!shared.contains("SEVO_UPSCALER=fsr"))
        // The other claimant's own exe is untouched by the launch.
        #expect(files["first.exe.env"] == ConfigMaterializer.appFiles([Self.rpgMakerA, Self.rpgMakerB])["first.exe.env"])
        // A launch of a game that shares nothing changes nothing.
        let alone = ConfigMaterializer.GameFiles(appID: 9, settings: ["# app 9"], exes: ["nine.exe"])
        #expect(ConfigMaterializer.appFiles([Self.rpgMakerA, alone], launching: 9)
            == ConfigMaterializer.appFiles([Self.rpgMakerA, alone]))
    }

    @Test
    func `a launch writes only the files of the exes it shares, under the app's header`() throws {
        let files = ConfigMaterializer.launchFiles(for: Self.rpgMakerB, among: [Self.rpgMakerA])
        #expect(Set(files.keys) == ["game.exe.env"])
        #expect(files["game.exe.env"]?.contains("SEVO_LOADER=/launchers/4000.app") == true)
        #expect(ConfigMaterializer.launchFiles(for: Self.rpgMakerA, among: []).isEmpty)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apps-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        ConfigMaterializer.writeFiles(files, in: dir)
        let written = try String(contentsOf: dir.appendingPathComponent("game.exe.env"), encoding: .utf8)
        #expect(written.hasPrefix("# written by Sevoflurane; edits are overwritten\n"))
        #expect(written.contains("\nSEVO_LOADER=/launchers/4000.app\n"))
    }

    @Test
    func `a Steam game with no manifest is not written for; an adopted program always is`() {
        var installedGame = ConfigValues.empty
        installedGame.exes = ["game.exe"]
        var uninstalledGame = ConfigValues.empty
        uninstalledGame.exes = ["game.exe"]
        uninstalledGame.fps = true
        var adopted = ConfigValues.empty
        adopted.exes = ["tool.exe"]
        var installedWithoutRecords = ConfigValues.empty
        installedWithoutRecords.name = "Unplayed"
        let games = [
            1_234_567: installedGame, 603_750: uninstalledGame,
            2_000_000_001: adopted, 99: installedWithoutRecords,
        ]
        let written = ConfigMaterializer.materializedGames(games, installed: [1_234_567, 99])
        #expect(written.map(\.appID) == [1_234_567, 2_000_000_001])
    }

    @Test
    func `seven calls made during a pass are answered by one more pass`() {
        let gate = CoalescingGate()
        let passes = Mutex(0)
        let waiting = Mutex(0)
        let callers = DispatchGroup()
        callers.enter()
        Thread {
            gate.run(key: "bottle") {
                passes.withLock { $0 += 1 }
                // Held until the other seven have called, so they all arrive
                // during this pass.
                while waiting.withLock({ $0 }) < 7 { Thread.sleep(forTimeInterval: 0.01) }
                Thread.sleep(forTimeInterval: 0.2)
            }
            callers.leave()
        }.start()
        while passes.withLock({ $0 }) == 0 { Thread.sleep(forTimeInterval: 0.01) }
        for _ in 0 ..< 7 {
            callers.enter()
            Thread {
                waiting.withLock { $0 += 1 }
                gate.run(key: "bottle") { passes.withLock { $0 += 1 } }
                callers.leave()
            }.start()
        }
        callers.wait()
        #expect(passes.withLock { $0 } == 2)
    }

    @Test
    func `a call made during a pass waits for a pass of its own`() async {
        let gate = CoalescingGate()
        let passes = Mutex(0)
        let first = Task.detached {
            gate.run(key: "bottle") {
                passes.withLock { $0 += 1 }
                Thread.sleep(forTimeInterval: 0.2)
            }
        }
        try? await Task.sleep(for: .milliseconds(50))
        await Task.detached {
            gate.run(key: "bottle") { passes.withLock { $0 += 1 } }
        }.value
        await first.value
        #expect(passes.withLock { $0 } == 2)
    }

    @Test
    func `a game's processor cap reaches its file, and every processor overrides the bottle`() {
        var values = ConfigValues.empty
        #expect(!ConfigMaterializer.gameLines(1, values).contains { $0.hasPrefix("SEVO_CPU_COUNT=") })
        values.processors = 8
        #expect(ConfigMaterializer.gameLines(1, values).contains("SEVO_CPU_COUNT=8"))
        // The bottle's file is read first, so a game asking for every
        // processor under a bottle that caps needs its own line.
        values.processors = 0
        #expect(ConfigMaterializer.gameLines(1, values).contains("SEVO_CPU_COUNT=0"))
    }
}

/// The last level of the settings hierarchy.
struct ConfigDefaultsTests {
    /// ``GameConfig/resolve(_:bottle:game:)`` unwraps the default when no
    /// level sets a key, so a resolved key without one ends the app.
    @Test
    func `the defaults set every key the hierarchy resolves`() {
        let defaults = GameConfig.defaults
        #expect(defaults.windows != nil)
        #expect(defaults.mouse != nil)
        #expect(defaults.tuning != nil)
        #expect(defaults.upscaler != nil)
        #expect(defaults.unifiedMemory != nil)
        #expect(defaults.filter != nil)
        #expect(defaults.retina != nil)
        #expect(defaults.emulateModeset != nil)
        #expect(defaults.hud != nil)
        #expect(defaults.fps != nil)
        #expect(defaults.largeAddressAware != nil)
        #expect(defaults.avx != nil)
        #expect(defaults.cursorConfine != nil)
        #expect(defaults.processors != nil)
    }
}

/// The `sevo` handed to the engine for its View menu, from each process that writes env files.
struct BundledCLITests {
    private func app() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-\(UUID().uuidString)/Sevoflurane.app")
        for path in ["Contents/MacOS/Sevoflurane", "Contents/Helpers/sevo", "Contents/Library/LaunchAgents/SevofluraneDaemon"] {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        return root
    }

    @Test
    func `the app and its daemon both hand over the app's own sevo`() throws {
        let root = try app()
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let sevo = root.appendingPathComponent("Contents/Helpers/sevo")
        #expect(ConfigMaterializer.cli(forExecutable: root.appendingPathComponent("Contents/MacOS/Sevoflurane")) == sevo)
        #expect(ConfigMaterializer.cli(
            forExecutable: root.appendingPathComponent("Contents/Library/LaunchAgents/SevofluraneDaemon"),
        ) == sevo)
    }

    @Test
    func `a sevo outside an app hands over itself and nothing else does`() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let sevo = directory.appendingPathComponent("sevo"), other = directory.appendingPathComponent("tool")
        for url in [sevo, other] {
            FileManager.default.createFile(atPath: url.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        }
        #expect(ConfigMaterializer.cli(forExecutable: sevo) == sevo)
        #expect(ConfigMaterializer.cli(forExecutable: other) == nil)
    }
}
