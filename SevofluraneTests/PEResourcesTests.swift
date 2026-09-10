import CoreGraphics
import Foundation
import Testing
@testable import Sevoflurane

/// Reading a Windows executable's own description of itself, against a
/// fixture built for the purpose.
///
/// `SevofluraneTests/Fixtures/fixture.exe` is a ten-line mingw program whose
/// resources are the point: an icon group with one entry per storage form the
/// parser handles (32-bit BGRA, 4-bit and 8-bit paletted, 24-bit, and a PNG
/// at 256), a full `StringFileInfo` table, and a manifest. `build.sh` beside
/// it rebuilds both the icon and the exe.
struct PEResourcesTests {
    /// The fixture, from this file's own path — the harness picks the working
    /// directory.
    private static let fixture = URL(filePath: #filePath)
        .deletingLastPathComponent()
        .appending(path: "Fixtures/fixture.exe")

    private static var info: PEResources.Info? {
        PEResources.read(fixture)
    }

    @Test
    func `a mingw executable reads as a PE image`() {
        #expect(PEResources.isExecutable(Self.fixture))
        #expect(PEResources.read(Self.fixture) != nil)
    }

    @Test
    func `a file that is not a PE image reads as nothing`() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "not-a-pe-\(UUID().uuidString).exe")
        try Data("this is not an executable".utf8).write(to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        #expect(!PEResources.isExecutable(temporary))
        #expect(PEResources.read(temporary) == nil)
    }

    @Test
    func `the version resource carries the strings the script wrote`() throws {
        let info = try #require(Self.info)
        #expect(info.productName == "Sevoflurane Fixture")
        #expect(info.fileDescription == "Sevoflurane PE fixture")
        #expect(info.fileVersion == "1.2.3.4")
        #expect(info.companyName == "kageroumado")
    }

    @Test
    func `the manifest's requested execution level is read`() throws {
        let info = try #require(Self.info)
        #expect(info.requestedExecutionLevel == "asInvoker")
    }

    @Test
    func `every icon in the group is found, at its own size`() throws {
        let info = try #require(Self.info)
        #expect(info.icons.map(\.pixels).sorted() == [16, 24, 32, 48, 256])
    }

    @Test
    func `the largest icon is the 256-pixel PNG`() throws {
        let largest = try #require(Self.info?.largestIcon)
        #expect(largest.pixels == 256)
        #expect(largest.isPNG)
    }

    @Test
    func `a PNG entry decodes to an image of its own size`() throws {
        let icon = try #require(Self.info?.icons.first { $0.pixels == 256 })
        let image = try #require(PEResources.image(of: icon))
        #expect(image.width == 256)
        #expect(image.height == 256)
    }

    /// The four DIB depths, each with an AND mask under it — the branch the
    /// PNG path never reaches.
    @Test(arguments: [16, 24, 32, 48])
    func `a DIB entry decodes to an image of its own size`(pixels: Int) throws {
        let icon = try #require(Self.info?.icons.first { $0.pixels == pixels })
        #expect(!icon.isPNG)
        let image = try #require(PEResources.image(of: icon))
        #expect(image.width == pixels)
        #expect(image.height == pixels)
    }

    @Test
    func `the file's own icon is the one it draws with`() throws {
        let image = try #require(PEResources.icon(at: Self.fixture))
        #expect(image.width == 256)
    }

    /// The bottle's own executables are the real proof, and a clone has no
    /// bottle — so this reads them when they are there and says nothing when
    /// they are not.
    @Test
    func `the bottle's own executables read the same way`() throws {
        let exes = Self.bottleExecutables()
        // A clone has no bottle, and a fixture that cannot exist is not a
        // failure of the parser.
        guard !exes.isEmpty else { return }
        for exe in exes {
            let info = try #require(PEResources.read(exe), "\(exe.lastPathComponent)")
            #expect(!info.icons.isEmpty, "\(exe.lastPathComponent) has no icon")
            let largest = try #require(info.largestIcon)
            #expect(PEResources.image(of: largest) != nil)
        }
    }

    /// Steam's own exe and the first few game executables in the bottle.
    private static func bottleExecutables() -> [URL] {
        let manager = FileManager.default
        var found: [URL] = []
        let steam = SteamBottle.steamRoot.appending(path: "steam.exe")
        if manager.fileExists(atPath: steam.path) { found.append(steam) }
        let common = SteamBottle.steamRoot.appending(path: "steamapps/common")
        for game in InstallDirectory.entries(in: common).prefix(3) where game.isDirectory {
            found += GameExecutables.executableURLs(in: game.url).prefix(1)
        }
        return found
    }
}
