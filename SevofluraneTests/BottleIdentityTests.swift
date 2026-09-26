import Foundation
import Testing
@testable import Sevoflurane

/// Keeping bottles apart: which bottle a stop reaches, when a restart may keep
/// Windows, and which running prefixes are strays. A prefix outside
/// Sevoflurane's bottles is never one, whatever engine it runs on.
struct BottleIdentityTests {
    private static let bottles = "/Users/me/Library/Application Support/Sevoflurane/Bottles"
    private static let steam = bottles + "/Steam"
    private static let retest = bottles + "/Retest26"
    private static let older = bottles + "/Older"
    /// A tester's own prefix on an engine from the same Engines folder.
    private static let outside = "/Users/me/gdiag/prefix"

    private static let steamServer = "/tmp/.wine-501/server-100000d-1"
    private static let retestServer = "/tmp/.wine-501/server-100000d-2"
    private static let olderServer = "/tmp/.wine-501/server-100000d-3"
    private static let outsideServer = "/tmp/.wine-501/server-100000d-9"

    private static let managed = [steamServer: steam, retestServer: retest, olderServer: older]

    private static func target(_ path: String, _ version: String = "dormison-r18") -> BottleTarget {
        BottleTarget(prefix: URL(fileURLWithPath: path), engine: .managed(version: version))
    }

    // MARK: - What a stop reaches

    @Test
    func `a stop reaches the booted bottle and the configured one`() {
        let set = BottleTarget.stopSet(booted: Self.target(Self.steam), configured: Self.target(Self.retest))
        #expect(set.map(\.path) == [Self.steam, Self.retest])
    }

    @Test
    func `one bottle booted and configured is reached once, through the booted engine`() {
        let set = BottleTarget.stopSet(
            booted: Self.target(Self.steam, "dormison-r17"), configured: Self.target(Self.steam, "dormison-r18"),
        )
        #expect(set.count == 1)
        #expect(set.first?.engine == .managed(version: "dormison-r17"))
    }

    @Test
    func `with no launch on record a stop reaches the configured bottle`() {
        #expect(BottleTarget.stopSet(booted: nil, configured: Self.target(Self.steam)).map(\.path) == [Self.steam])
    }

    @Test
    func `a quit reaches strays after the booted and the configured bottle, each once`() {
        let set = BottleTarget.stopSet(
            booted: Self.target(Self.steam), configured: Self.target(Self.retest),
            strays: [Self.target(Self.older), Self.target(Self.steam)],
        )
        #expect(set.map(\.path) == [Self.steam, Self.retest, Self.older])
    }

    @Test
    func `a stop that reaches beyond the configured bottle says so`() {
        let configured = Self.target(Self.retest)
        #expect(BottleTarget.scopeNote([configured], configured: configured) == "bottle Retest26")
        #expect(
            BottleTarget.scopeNote([Self.target(Self.steam), configured], configured: configured)
                == "bottles Steam, Retest26 (configured: Retest26)",
        )
    }

    // MARK: - A restart

    private static let boot = BottleIdentity.Boot(engineRoot: "/e/dormison-r18", msync: true, bottle: steam)

    @Test
    func `Windows stays through a restart only when engine, msync and bottle all match`() {
        #expect(BottleIdentity.windowsCanStay(booted: Self.boot, current: Self.boot))
        var moved = Self.boot
        moved.bottle = Self.retest
        #expect(!BottleIdentity.windowsCanStay(booted: Self.boot, current: moved))
        moved = Self.boot
        moved.engineRoot = "/e/dormison-r17"
        #expect(!BottleIdentity.windowsCanStay(booted: Self.boot, current: moved))
        moved = Self.boot
        moved.msync = false
        #expect(!BottleIdentity.windowsCanStay(booted: Self.boot, current: moved))
    }

    @Test
    func `a boot with no bottle on record takes Windows down`() {
        var unknown = Self.boot
        unknown.bottle = nil
        #expect(!BottleIdentity.windowsCanStay(booted: unknown, current: Self.boot))
    }

    @Test
    func `a bottle chosen since the boot is a move, and no record is none`() {
        #expect(BottleIdentity.bottleMoved(booted: Self.steam, configured: Self.retest))
        #expect(!BottleIdentity.bottleMoved(booted: Self.steam, configured: Self.steam))
        #expect(!BottleIdentity.bottleMoved(booted: nil, configured: Self.retest))
    }

    // MARK: - Classifying what runs

    @Test
    func `the configured bottle's client alone is ours`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: Self.steam,
            servers: [.init(serverDirectory: Self.steamServer, engineVersion: "dormison-r18")],
            bottles: Self.managed, configured: Self.steam,
        )
        #expect(verdict.isOurs)
    }

    @Test
    func `a client in another Sevoflurane bottle is foreign and carries its engine`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: Self.steam,
            servers: [.init(serverDirectory: Self.steamServer, engineVersion: "dormison-r17")],
            bottles: Self.managed, configured: Self.retest,
        )
        #expect(verdict.foreignClient == BottleIdentity.Stray(prefix: Self.steam, engineVersion: "dormison-r17"))
        #expect(verdict.extras.isEmpty)
        #expect(verdict.strays.map(\.name) == ["Steam"])
    }

    @Test
    func `another Sevoflurane bottle's wineserver beside the configured client is extra`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: Self.retest,
            servers: [
                .init(serverDirectory: Self.retestServer, engineVersion: "dormison-r18"),
                .init(serverDirectory: Self.steamServer, engineVersion: "dormison-r18"),
                .init(serverDirectory: Self.olderServer, engineVersion: "dormison-r16"),
            ],
            bottles: Self.managed, configured: Self.retest,
        )
        #expect(verdict.foreignClient == nil)
        #expect(verdict.extras.map(\.name) == ["Older", "Steam"])
        #expect(verdict.extras.first?.engineVersion == "dormison-r16")
    }

    @Test
    func `a foreign client's own wineserver is not counted again as extra`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: Self.steam,
            servers: [
                .init(serverDirectory: Self.steamServer, engineVersion: "dormison-r18"),
                .init(serverDirectory: Self.retestServer, engineVersion: "dormison-r18"),
            ],
            bottles: Self.managed, configured: Self.retest,
        )
        #expect(verdict.strays.map(\.name) == ["Steam"])
    }

    @Test
    func `a prefix outside Sevoflurane's bottles is never a stray, even on a managed engine`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: Self.outside,
            servers: [
                .init(serverDirectory: Self.outsideServer, engineVersion: "dormison-r12"),
                .init(serverDirectory: Self.steamServer, engineVersion: "dormison-r18"),
            ],
            bottles: Self.managed, configured: Self.steam,
        )
        #expect(verdict.strays.isEmpty)
        #expect(verdict.outsideClient == Self.outside)
        #expect(!verdict.isOurs)
    }

    @Test
    func `a running outside prefix with no client on the port changes nothing`() {
        let verdict = BottleIdentity.classify(
            clientPrefix: nil,
            servers: [.init(serverDirectory: Self.outsideServer, engineVersion: "dormison-r12")],
            bottles: Self.managed, configured: Self.steam,
        )
        #expect(verdict.isOurs)
    }

    @Test
    func `a CrossOver bottle configured and answering is ours`() {
        let crossOver = "/Users/me/Library/Application Support/CrossOver/Bottles/Steam"
        let verdict = BottleIdentity.classify(
            clientPrefix: crossOver, servers: [], bottles: Self.managed, configured: crossOver,
        )
        #expect(verdict.isOurs)
    }

    @Test
    func `only folders under the bottles root are bottles`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("bottle-identity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Steam"), withIntermediateDirectories: true,
        )
        try Data().write(to: root.appendingPathComponent(".DS_Store"))
        try Data().write(to: root.appendingPathComponent("notes.txt"))
        defer { try? FileManager.default.trashItem(at: root, resultingItemURL: nil) }
        let bottles = BottleIdentity.managedBottles(root: root)
        let steam = root.appendingPathComponent("Steam").resolvingSymlinksInPath().path
        #expect(Array(bottles.values) == [steam])
        #expect(bottles.keys.first == WineOrphans.serverDirectory(forPrefix: steam))
    }

    // MARK: - Reading the machine

    @Test
    func `the kernel's private tmp is the server directory Wine names`() {
        #expect(
            BottleIdentity.canonicalServerDirectory("/private/tmp/.wine-501/server-100000d-eba1b76")
                == "/tmp/.wine-501/server-100000d-eba1b76",
        )
        #expect(BottleIdentity.canonicalServerDirectory(Self.steam) == Self.steam)
    }

    @Test
    func `a wineserver's engine is the folder under the engines root`() {
        let root = "/Users/me/Library/Application Support/Sevoflurane/Engines"
        #expect(
            BottleIdentity.engineVersion(ofExecutable: root + "/dormison-r18/wine/bin/wineserver", under: root)
                == "dormison-r18",
        )
        #expect(BottleIdentity.engineVersion(
            ofExecutable: "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wineserver", under: root,
        ) == nil)
        #expect(BottleIdentity.engineVersion(ofExecutable: root + "2/x/wineserver", under: root) == nil)
    }

    @Test
    func `lsof's listeners are its p lines`() {
        #expect(BottleIdentity.listenerPIDs(inLsofFields: "p73727\nf822\np73907\nf310\n") == [73727, 73907])
        #expect(BottleIdentity.listenerPIDs(inLsofFields: "").isEmpty)
    }

    // MARK: - Saying it

    @Test
    func `status names the client's bottle and the configured one when they differ`() {
        #expect(
            BottleIdentity.statusText(clientBottle: "Steam", configured: "Retest26", steamInstalled: true)
                == "client bottle Steam · configured bottle Retest26 (steam ok)",
        )
        #expect(
            BottleIdentity.statusText(clientBottle: "Steam", configured: "Steam", steamInstalled: true)
                == "bottle Steam (steam ok)",
        )
        #expect(
            BottleIdentity.statusText(clientBottle: nil, configured: "Retest26", steamInstalled: false)
                == "bottle Retest26 (no steam)",
        )
    }
}
