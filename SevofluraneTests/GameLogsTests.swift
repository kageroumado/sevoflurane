import Foundation
import Testing
@testable import Sevoflurane

/// What joins a Unity player's `Player.log` to the launch that produced it:
/// the identity in the game's own install, rather than the write times two
/// games up at once both match.
struct GameLogsTests {
    private let manager = FileManager.default

    /// A scratch directory, removed by the caller.
    private func scratch() throws -> URL {
        let url = manager.temporaryDirectory
            .appendingPathComponent("game-logs-tests-\(UUID().uuidString)")
        try manager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A game's install with one player data directory carrying `app.info`.
    @discardableResult
    private func makeInstall(
        in root: URL, named name: String, player: String, company: String, product: String,
    ) throws -> URL {
        let install = root.appendingPathComponent(name)
        let data = install.appendingPathComponent("\(player)\(GameLogsTests.dataSuffix)")
        try manager.createDirectory(at: data, withIntermediateDirectories: true)
        // No trailing newline: the player writes the two names exactly as the
        // one it created its `LocalLow` directories from.
        try Data("\(company)\n\(product)".utf8)
            .write(to: data.appendingPathComponent("app.info"))
        return install
    }

    private static let dataSuffix = "_Data"

    /// A Windows profile tree with one product's logs under `LocalLow`.
    private func makeLocalLow(
        in root: URL, user: String = "crossover", company: String, product: String,
        files: [String] = GameLogs.unityLogNames,
    ) throws -> URL {
        let users = root.appendingPathComponent("users")
        let directory = users
            .appendingPathComponent("\(user)/AppData/LocalLow/\(company)/\(product)")
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data("\(file) of \(product)\n".utf8)
                .write(to: directory.appendingPathComponent(file))
        }
        return users
    }

    @Test
    func `app_info names the company and the product a game logs under`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let install = try makeInstall(
            in: root, named: "Aka Manto  赤マント", player: "Aka Manto",
            company: "Hitori de Yoru", product: "Aka Manto",
        )
        let identity = try #require(
            GameLogs.unityIdentity(inInstall: install, exe: "aka manto.exe"),
        )
        #expect(identity.company == "Hitori de Yoru")
        #expect(identity.product == "Aka Manto")
    }

    @Test
    func `the player the run's executable names is read first`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let install = try makeInstall(
            in: root, named: "Two Players", player: "Launcher",
            company: "Wrong Company", product: "Launcher",
        )
        let game = install.appendingPathComponent("TheGame\(Self.dataSuffix)")
        try manager.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("Right Company\nThe Game".utf8)
            .write(to: game.appendingPathComponent("app.info"))
        let identity = try #require(
            GameLogs.unityIdentity(inInstall: install, exe: "thegame.exe"),
        )
        #expect(identity.company == "Right Company")
        #expect(identity.product == "The Game")
    }

    @Test
    func `an install with no app_info says nothing`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let install = root.appendingPathComponent("Plain Game/Plain Game_Data")
        try manager.createDirectory(at: install, withIntermediateDirectories: true)
        #expect(
            GameLogs.unityIdentity(
                inInstall: root.appendingPathComponent("Plain Game"), exe: "plain game.exe",
            ) == nil,
        )
    }

    @Test
    func `the identity takes the log it rotated as well as the live one`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let users = try makeLocalLow(in: root, company: "Landfall", product: "TABS")
        let found = GameLogs.unityLogs(company: "Landfall", product: "TABS", underUsers: users)
            .map(\.lastPathComponent)
        #expect(found == ["Player.log", "Player-prev.log"])
    }

    @Test
    func `a product with only a live log contributes only that one`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let users = try makeLocalLow(
            in: root, company: "Landfall", product: "TABS", files: ["Player.log"],
        )
        let found = GameLogs.unityLogs(company: "Landfall", product: "TABS", underUsers: users)
        #expect(found.map(\.lastPathComponent) == ["Player.log"])
    }

    @Test
    func `the LocalLow directories are matched however they are cased`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let users = try makeLocalLow(in: root, company: "ACQUIRE Corp", product: "HookahHaze")
        let found = GameLogs.unityLogs(
            company: "acquire corp", product: "hookahhaze", underUsers: users,
        )
        #expect(found.count == 2)
    }

    @Test
    func `a game that has never written takes nobody else's log`() throws {
        let root = try scratch()
        defer { try? manager.removeItem(at: root) }
        let users = try makeLocalLow(in: root, company: "Project Moon", product: "LimbusCompany")
        let found = GameLogs.unityLogs(
            company: "Hitori de Yoru", product: "Aka Manto", underUsers: users,
        )
        #expect(found.isEmpty)
    }

    @Test
    func `two files of one app id keep their own place in the report`() {
        let first = URL(fileURLWithPath: "/x/Landfall/TABS/Player.log")
        let second = URL(fileURLWithPath: "/x/Project Moon/LimbusCompany/Player.log")
        let third = URL(fileURLWithPath: "/y/Project Moon/LimbusCompany/Player.log")
        var taken: Set<String> = []
        var paths: [String] = []
        for url in [first, second, third] {
            let path = GameLogs.path(of: url, forApp: 508_440, avoiding: taken)
            taken.insert(path)
            paths.append(path)
        }
        #expect(paths == [
            "games/508440/Player.log",
            "games/508440/LimbusCompany/Player.log",
            "games/508440/LimbusCompany-2/Player.log",
        ])
    }
}
