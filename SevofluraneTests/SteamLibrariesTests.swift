import Foundation
import Testing
@testable import Sevoflurane

/// Reading Steam's `libraryfolders.vdf`, on text shaped like the file Steam
/// writes, and finding each library's `steamapps` on disk.
struct SteamLibrariesTests {
    private static let current = #"""
    "libraryfolders"
    {
    	"0"
    	{
    		"path"		"C:\\Program Files (x86)\\Steam"
    		"label"		""
    		"contentid"		"645996540939681052"
    		"apps"
    		{
    			"228980"		"241762497"
    			"1962700"		"16427856745"
    		}
    	}
    	"1"
    	{
    		"path"		"Z:\\Volumes\\Games\\SteamLibrary"
    		"apps"
    		{
    			"310360"		"1400000000"
    		}
    	}
    }
    """#

    @Test
    func `each library's path is read in file order and unescaped`() {
        #expect(SteamLibraries.paths(inLibraryFolders: Self.current) == [
            #"C:\Program Files (x86)\Steam"#, #"Z:\Volumes\Games\SteamLibrary"#,
        ])
    }

    /// An app id and its size have the same shape as the older file's
    /// numbered path entries; only a path is a library.
    @Test
    func `the apps block is not read as libraries`() {
        let paths = SteamLibraries.paths(inLibraryFolders: Self.current)
        #expect(!paths.contains("241762497"))
        #expect(paths.count == 2)
    }

    @Test
    func `the older shape with a path as each numbered value is read`() {
        let older = #"""
        "LibraryFolders"
        {
        	"TimeNextStatsReport"		"1600000000"
        	"ContentStatsID"		"-123"
        	"1"		"D:\\SteamLibrary"
        }
        """#
        #expect(SteamLibraries.paths(inLibraryFolders: older) == [#"D:\SteamLibrary"#])
    }

    @Test
    func `a library whose drive is gone is left out and the bottle's own comes first`() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "libraries-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let steam = root.appending(path: "Steam")
        let external = root.appending(path: "External/SteamLibrary")
        try FileManager.default.createDirectory(
            at: steam.appending(path: "steamapps"), withIntermediateDirectories: true,
        )
        try FileManager.default.createDirectory(
            at: external.appending(path: "steamapps"), withIntermediateDirectories: true,
        )
        try Self.current.write(
            to: steam.appending(path: "steamapps/libraryfolders.vdf"), atomically: true, encoding: .utf8,
        )
        let resolved: [String: URL] = [
            #"C:\Program Files (x86)\Steam"#: steam,
            #"Z:\Volumes\Games\SteamLibrary"#: external,
        ]
        let found = SteamLibraries.steamapps(steamRoot: steam) { resolved[$0] }.map(\.standardizedFileURL.path)
        #expect(found == [
            steam.appending(path: "steamapps").standardizedFileURL.path,
            external.appending(path: "steamapps").standardizedFileURL.path,
        ])

        try FileManager.default.removeItem(at: external)
        #expect(SteamLibraries.steamapps(steamRoot: steam) { resolved[$0] }.count == 1)
    }

    @Test
    func `drives Wine cannot rely on are named for the warning`() {
        #expect(SteamLibraries.fileSystem(named: "apfs") == .mac)
        #expect(SteamLibraries.fileSystem(named: "hfs") == .mac)
        #expect(SteamLibraries.fileSystem(named: "exfat") == .foreign("exFAT"))
        #expect(SteamLibraries.fileSystem(named: "msdos") == .foreign("FAT"))
        #expect(SteamLibraries.fileSystem(named: "ntfs") == .foreign("NTFS"))
        #expect(SteamLibraries.fileSystem(named: "smbfs") == .network("SMBFS"))
    }
}
