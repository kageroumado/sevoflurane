import Darwin
import Foundation
import Testing
@testable import Sevoflurane

/// A Steam for Mac library and a bottle library side by side in a temporary
/// folder, which is one APFS volume.
private struct Libraries {
    let base = FileManager.default.temporaryDirectory.appending(path: "mac-copy-\(UUID().uuidString)")
    var macRoot: URL { base.appending(path: "SteamForMac") }
    var macSteamapps: URL { macRoot.appending(path: "steamapps") }
    var bottleSteamapps: URL { base.appending(path: "Bottle/steamapps") }
    var game: URL { macSteamapps.appending(path: "common/Test Game") }

    init(stateFlags: Int = 4) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: game.appending(path: "Game.app/Contents/Frameworks/SDL2.framework/Versions/A"), withIntermediateDirectories: true)
        try manager.createDirectory(at: bottleSteamapps, withIntermediateDirectories: true)
        try Data("binary".utf8).write(to: game.appending(path: "Game.app/Contents/Frameworks/SDL2.framework/Versions/A/SDL2"))
        try manager.createSymbolicLink(
            atPath: game.appending(path: "Game.app/Contents/Frameworks/SDL2.framework/Versions/Current").path,
            withDestinationPath: "A",
        )
        try """
        "AppState"
        {
        \t"appid"\t\t"42"
        \t"name"\t\t"Test Game"
        \t"StateFlags"\t\t"\(stateFlags)"
        \t"installdir"\t\t"Test Game"
        \t"SizeOnDisk"\t\t"6"
        \t"buildid"\t\t"7"
        }
        """.write(to: macSteamapps.appending(path: "appmanifest_42.acf"), atomically: true, encoding: .utf8)
    }

    func remove() {
        try? FileManager.default.removeItem(at: base)
    }
}

struct SteamForMacCopyTests {
    @Test
    func `a fully installed game at rest is a copy to take`() throws {
        let libraries = try Libraries()
        defer { libraries.remove() }
        let copy = try #require(SteamForMacCopy.copy(appID: 42, root: libraries.macRoot))
        #expect(copy.installDir == "Test Game")
        #expect(copy.buildID == "7")
        #expect(copy.bytes == 6)
        #expect(SteamForMacCopy.copy(appID: 43, root: libraries.macRoot) == nil)
    }

    @Test(arguments: [6, 1028, 1542])
    func `a game with an update pending or running is no copy`(flags: Int) throws {
        let libraries = try Libraries(stateFlags: flags)
        defer { libraries.remove() }
        #expect(SteamForMacCopy.copy(appID: 42, root: libraries.macRoot) == nil)
    }

    @Test
    func `a game with a download staged is no copy`() throws {
        let libraries = try Libraries()
        defer { libraries.remove() }
        try FileManager.default.createDirectory(
            at: libraries.macSteamapps.appending(path: "downloading/42"), withIntermediateDirectories: true,
        )
        #expect(SteamForMacCopy.copy(appID: 42, root: libraries.macRoot) == nil)
    }

    @Test
    func `the clone lands whole with its symlinks and leaves the source as it was`() throws {
        let libraries = try Libraries()
        defer { libraries.remove() }
        let copy = try #require(SteamForMacCopy.copy(appID: 42, root: libraries.macRoot))
        #expect(SteamForMacCopy.refusal(for: copy, in: libraries.bottleSteamapps) == nil)
        let target = try SteamForMacCopy.clone(copy, into: libraries.bottleSteamapps)
        let framework = "Game.app/Contents/Frameworks/SDL2.framework"
        #expect(try String(contentsOf: target.appending(path: "\(framework)/Versions/A/SDL2"), encoding: .utf8) == "binary")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: target.appending(path: "\(framework)/Versions/Current").path) == "A")
        #expect(try FileManager.default.contentsOfDirectory(atPath: libraries.bottleSteamapps.appending(path: "common").path) == ["Test Game"])
        #expect(FileManager.default.fileExists(atPath: libraries.game.appending(path: "\(framework)/Versions/A/SDL2").path))
    }

    @Test
    func `a folder of the same name in the bottle is never overwritten`() throws {
        let libraries = try Libraries()
        defer { libraries.remove() }
        let existing = libraries.bottleSteamapps.appending(path: "common/Test Game")
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        let copy = try #require(SteamForMacCopy.copy(appID: 42, root: libraries.macRoot))
        guard case let .targetExists(target)? = SteamForMacCopy.refusal(for: copy, in: libraries.bottleSteamapps) else {
            Issue.record("expected the existing folder to refuse the clone")
            return
        }
        #expect(target.standardizedFileURL.path == existing.standardizedFileURL.path)
        #expect(throws: SteamForMacCopy.Refusal.self) {
            try SteamForMacCopy.clone(copy, into: libraries.bottleSteamapps)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: existing.path).isEmpty)
    }
}

struct ReparseLinksTests {
    /// `Versions/Current -> A` and `Headers -> Versions/Current/Headers`, as
    /// Wine wrote them for To the Moon's SDL2.framework.
    static let current = Data([
        0x0C, 0x00, 0x00, 0xA0, 0x14, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x04, 0x00, 0x02, 0x00,
        0x01, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00,
    ])
    static let headers: Data = {
        let path = Array("Versions\\Current\\Headers".utf16)
        var bytes: [UInt8] = [0x0C, 0x00, 0x00, 0xA0, 0x70, 0x00, 0x00, 0x00, 0x00, 0x00, 0x30, 0x00, 0x32, 0x00, 0x30, 0x00, 0x01, 0x00, 0x00, 0x00]
        for _ in 0 ..< 2 {
            for unit in path { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
            bytes += [0, 0]
        }
        return Data(bytes)
    }()

    static func reparse(_ target: String, relative: Bool = true) -> Data {
        let units = Array(target.utf16)
        var bytes: [UInt8] = [0x0C, 0x00, 0x00, 0xA0, 0, 0, 0, 0, 0, 0]
        bytes += [UInt8(units.count * 2 & 0xFF), UInt8(units.count * 2 >> 8), 0, 0, 0, 0, relative ? 1 : 0, 0, 0, 0]
        for unit in units { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        return Data(bytes)
    }

    private static func writeReparse(_ data: Data, at url: URL) throws {
        try Data().write(to: url)
        let result = data.withUnsafeBytes { setxattr(url.path, ReparseLinks.attribute, $0.baseAddress, data.count, 0, 0) }
        #expect(result == 0)
    }

    @Test
    func `steam's commit leftovers are told apart from depot names`() {
        #expect(ReparseLinks.isCommitLeftover("rff293.tmp"))
        #expect(ReparseLinks.isCommitLeftover("rff1a2b.tmp"))
        #expect(!ReparseLinks.isCommitLeftover("rff.tmp"))
        #expect(!ReparseLinks.isCommitLeftover("Headers"))
        #expect(!ReparseLinks.isCommitLeftover("rffle.tmp.bak"))
    }

    @Test
    func `a relative symlink's target reads with forward slashes`() {
        #expect(ReparseLinks.relativeTarget(ofReparseData: Self.current) == "A")
        #expect(ReparseLinks.relativeTarget(ofReparseData: Self.headers) == "Versions/Current/Headers")
        #expect(ReparseLinks.relativeTarget(ofReparseData: Self.reparse("C:\\Windows", relative: false)) == nil)
        #expect(ReparseLinks.relativeTarget(ofReparseData: Data([0x03, 0x00, 0x00, 0xA0] + Array(repeating: 0, count: 20))) == nil)
    }

    @Test
    func `wine symlinks become real ones once, and taken names stay as they are`() throws {
        let base = FileManager.default.temporaryDirectory.appending(path: "reparse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let framework = base.appending(path: "Game.app/Contents/Frameworks/SDL2.framework")
        try FileManager.default.createDirectory(at: framework.appending(path: "Versions/A/Headers"), withIntermediateDirectories: true)
        try Self.writeReparse(Self.current, at: framework.appending(path: "Versions/Current?"))
        try Self.writeReparse(Self.headers, at: framework.appending(path: "Headers?"))
        try Self.writeReparse(Self.reparse("..\\..\\..\\..\\..\\..\\etc"), at: framework.appending(path: "Escape?"))
        try FileManager.default.createDirectory(at: framework.appending(path: "Resources"), withIntermediateDirectories: true)
        try Self.writeReparse(Self.reparse("Versions\\Current\\Resources"), at: framework.appending(path: "Resources?"))

        try Self.writeReparse(Self.reparse("Versions\\Current\\Headers"), at: framework.appending(path: "rff293.tmp?"))

        #expect(ReparseLinks.restore(in: base) == 2)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: framework.appending(path: "rff293.tmp").path)) == nil)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: framework.appending(path: "Versions/Current").path) == "A")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: framework.appending(path: "Headers").path) == "Versions/Current/Headers")
        #expect(FileManager.default.fileExists(atPath: framework.appending(path: "Headers").path))
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: framework.appending(path: "Escape").path)) == nil)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: framework.appending(path: "Resources").path)) == nil)
        #expect(ReparseLinks.restore(in: base) == 0)
    }
}
