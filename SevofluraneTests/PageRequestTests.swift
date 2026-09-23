import Foundation
import Testing
@testable import Sevoflurane

/// What the page may make the app do on the Mac: which frames are heard, and
/// what a folder request opens.
struct PageRequestTests {
    @Test
    func `a plain folder is opened`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(SteamWindow.directoryToReveal(folder) == .open(folder))
    }

    @Test
    func `an app or a file is selected, never opened`() throws {
        let folder = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: folder) }
        let app = folder.appendingPathComponent("Calculator.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let script = folder.appendingPathComponent("run.command")
        try Data("#!/bin/sh\n".utf8).write(to: script)
        #expect(SteamWindow.directoryToReveal(app) == .select(app))
        #expect(SteamWindow.directoryToReveal(script) == .select(script))
    }

    @Test
    func `a message from the UI's top document is heard`() {
        #expect(SteamWebCoordinator.admitsMessage(isMainFrame: true, origin: ("http", "127.0.0.1", 8762)))
    }

    @Test
    func `a message from an embedded frame or another origin is dropped`() {
        #expect(!SteamWebCoordinator.admitsMessage(isMainFrame: false, origin: ("http", "127.0.0.1", 8762)))
        #expect(!SteamWebCoordinator.admitsMessage(isMainFrame: true, origin: ("https", "store.steampowered.com", 443)))
        #expect(!SteamWebCoordinator.admitsMessage(isMainFrame: true, origin: ("http", "127.0.0.1", 8764)))
        #expect(!SteamWebCoordinator.admitsMessage(isMainFrame: true, origin: ("", "", 0)))
    }

    @Test
    func `a window size the page asks for is held to what a window can be`() {
        #expect(SteamWindow.clampedSize(width: 800, height: 600) == CGSize(width: 800, height: 600))
        #expect(SteamWindow.clampedSize(width: -5, height: 1e12) == CGSize(width: 0, height: SteamWindow.maximumSide))
    }

    @Test
    func `a window position keeps parking room and loses the absurd`() {
        #expect(SteamWindow.clampedOffset(99788) == 99788)
        #expect(SteamWindow.clampedOffset(-1e15) == -SteamWindow.maximumOffset)
    }

    private static func scratch() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PageRequestTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
