import Foundation
import Testing
@testable import Sevoflurane

/// Steam for Mac's installs, read from its own files, and where a Play goes.
struct NativeSteamTests {
    /// A manifest as Steam for Mac writes it, with a nested block whose keys
    /// repeat the top-level ones.
    private static func manifest(appID: Int, flags: Int) -> String {
        """
        "AppState"
        {
        	"appid"		"\(appID)"
        	"universe"		"1"
        	"name"		"Hades II"
        	"StateFlags"		"\(flags)"
        	"installdir"		"Hades II"
        	"SizeOnDisk"		"10737418240"
        	"InstalledDepots"
        	{
        		"1145351"
        		{
        			"manifest"		"4182345917036514107"
        			"size"		"10737418240"
        		}
        	}
        	"UserConfig"
        	{
        		"name"		"other"
        	}
        }
        """
    }

    @Test
    func `a manifest names its game and whether every file is there`() throws {
        let installed = try #require(NativeSteam.game(inManifest: Self.manifest(appID: 1_145_350, flags: 4)))
        #expect(installed == NativeSteam.Game(appID: 1_145_350, name: "Hades II", stateFlags: 4))
        #expect(installed.isFullyInstalled)
        // Fully installed with an update queued (4 | 2) is still playable.
        #expect(NativeSteam.game(inManifest: Self.manifest(appID: 1, flags: 6))?.isFullyInstalled == true)
        // Downloading (1024) without the installed bit is not.
        #expect(NativeSteam.game(inManifest: Self.manifest(appID: 1, flags: 1026))?.isFullyInstalled == false)
        #expect(NativeSteam.game(inManifest: "\"AppState\" { }") == nil)
    }

    @Test
    func `a game is installed when any library holds a full manifest for it`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "native-steam-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appending(path: "Steam")
        let external = root.appending(path: "External/SteamLibrary")
        for library in [steam, external] {
            try FileManager.default.createDirectory(
                at: library.appending(path: "steamapps"), withIntermediateDirectories: true,
            )
        }
        try """
        "libraryfolders"
        {
        	"0"
        	{
        		"path"		"\(steam.path)"
        		"apps"
        		{
        			"620"		"12884901888"
        		}
        	}
        	"1"
        	{
        		"path"		"\(external.path)"
        	}
        }
        """.write(to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8)
        try Self.manifest(appID: 620, flags: 1026)
            .write(to: steam.appending(path: "steamapps/appmanifest_620.acf"), atomically: true, encoding: .utf8)
        try Self.manifest(appID: 1_145_350, flags: 4)
            .write(to: external.appending(path: "steamapps/appmanifest_1145350.acf"), atomically: true, encoding: .utf8)

        #expect(NativeSteam.steamapps(root: steam).map(\.standardizedFileURL.path) == [
            steam.appending(path: "steamapps").standardizedFileURL.path,
            external.appending(path: "steamapps").standardizedFileURL.path,
        ])
        #expect(NativeSteam.isInstalled(appID: 1_145_350, root: steam))
        #expect(!NativeSteam.isInstalled(appID: 620, root: steam))
        #expect(!NativeSteam.isInstalled(appID: 70, root: steam))
        #expect(NativeSteam.steamapps(root: root.appending(path: "Missing")).isEmpty)
    }

    @Test
    func `Play goes to Steam for Mac only for a game set to its macOS build`() {
        #expect(MacBuildRoute.decide(appID: 7, build: nil, hasSteamForMac: true, installedThere: true) == .windows)
        #expect(MacBuildRoute.decide(appID: 7, build: .windows, hasSteamForMac: true, installedThere: true) == .windows)
        #expect(MacBuildRoute.decide(appID: 7, build: .mac, hasSteamForMac: true, installedThere: true) == .play(7))
        #expect(MacBuildRoute.decide(appID: 7, build: .mac, hasSteamForMac: true, installedThere: false) == .install(7))
        #expect(
            MacBuildRoute.decide(appID: 7, build: .mac, hasSteamForMac: false, installedThere: true)
                == .steamForMacMissing(7),
        )
    }

    @Test
    func `the links Steam for Mac is handed`() {
        #expect(MacBuildRoute.play(1_145_350).link?.absoluteString == "steam://rungameid/1145350")
        #expect(MacBuildRoute.install(1_145_350).link?.absoluteString == "steam://install/1145350")
        #expect(MacBuildRoute.windows.link == nil)
        #expect(MacBuildRoute.steamForMacMissing(1).link == nil)
    }

    // MARK: - Steam for Mac as an option

    @Test
    func `Steam for Mac is always offered on an engine without macOS versions`() {
        #expect(NativeSteam.isOffered(enginePlaysMacOS: false, optedIn: false))
        #expect(NativeSteam.isOffered(enginePlaysMacOS: false, optedIn: true))
    }

    @Test
    func `Steam for Mac is an option on an engine that plays macOS versions`() {
        #expect(!NativeSteam.isOffered(enginePlaysMacOS: true, optedIn: false))
        #expect(NativeSteam.isOffered(enginePlaysMacOS: true, optedIn: true))
    }
}
