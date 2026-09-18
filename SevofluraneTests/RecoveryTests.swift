import Foundation
import Testing
@testable import Sevoflurane

/// The Recovery pane's model: the resets it offers, the known issues it names,
/// and — the load-bearing one — that the shader-cache reset can only reach a
/// regenerable cache, never saves or game files.
@MainActor
struct RecoveryTests {
    @Test
    func `the pane offers exactly the four confirming resets`() {
        #expect(RecoverySettings.Reset.allCases == [
            .forceQuitSteam, .restartWindows, .clearShaderCache, .rebuildSteamEnvironment,
        ])
    }

    @Test
    func `the rebuild says how long it takes and what it keeps`() {
        let rebuild = RecoverySettings.Reset.rebuildSteamEnvironment
        #expect(rebuild.message.contains("games and saves stay"))
        #expect(rebuild.message.lowercased().contains("minutes"))
    }

    @Test
    func `the report is written by the sevo helper inside this bundle`() {
        let helper = RecoverySettings.diagnosticsHelper
        #expect(helper.path.hasSuffix("/Contents/Helpers/sevo"))
        #expect(helper.path.hasPrefix(Bundle.main.bundleURL.standardizedFileURL.path + "/"))
    }

    @Test
    func `every reset has a title, a message, and a confirm label`() {
        for reset in RecoverySettings.Reset.allCases {
            #expect(!reset.title.isEmpty)
            #expect(!reset.message.isEmpty)
            #expect(!reset.confirmLabel.isEmpty)
        }
    }

    @Test
    func `known issues are present, uniquely identified, and each carries a fix`() {
        let issues = RecoverySettings.knownIssues
        #expect(!issues.isEmpty)
        #expect(Set(issues.map(\.id)).count == issues.count)
        for issue in issues {
            #expect(!issue.symptom.isEmpty)
            #expect(!issue.fix.isEmpty)
        }
        // The two issues whose fix is a button in this pane must be listed.
        let ids = Set(issues.map(\.id))
        #expect(ids.contains("helper-wont-start"))
        #expect(ids.contains("d3dcompiler-missing"))
    }
}

/// The shader-cache reset is the only new one that deletes anything, so its
/// target is pinned to `steamapps/shadercache` — a regenerable cache Steam
/// rebuilds — and proven never to resolve onto saves, game files, or the
/// prefix. A wrong path here would delete someone's library.
struct ShaderCacheSafetyTests {
    private var shaderCache: String { SteamBottle.shaderCache.standardizedFileURL.path }

    @Test
    func `the cache path is steamapps slash shadercache under the Steam root`() {
        #expect(shaderCache.hasSuffix("/steamapps/shadercache"))
        let steamRoot = SteamBottle.steamRoot.standardizedFileURL.path
        #expect(shaderCache.hasPrefix(steamRoot + "/"))
        #expect(shaderCache != steamRoot)
    }

    @Test
    func `the cache path never resolves onto saves, games, or the Windows user tree`() {
        // Games live in steamapps/common; Steam cloud saves in userdata; game
        // saves under the Windows user profile. None may be a component of the
        // path the reset trashes.
        #expect(!shaderCache.contains("/steamapps/common"))
        #expect(!shaderCache.contains("/userdata"))
        #expect(!shaderCache.contains("/drive_c/users/"))
    }

    @Test
    func `the cache path is strictly inside the bottle, never the bottle or drive_c itself`() {
        let bottle = SteamBottle.root.standardizedFileURL.path
        let driveC = SteamBottle.root.appendingPathComponent("drive_c").standardizedFileURL.path
        #expect(shaderCache.hasPrefix(bottle + "/"))
        #expect(shaderCache != bottle)
        #expect(shaderCache != driveC)
        // Deeper than drive_c: it cannot be a parent of the game or user trees.
        #expect(shaderCache.hasPrefix(driveC + "/"))
        #expect(shaderCache.count > driveC.count + "/steamapps/shadercache".count - 1)
    }
}
