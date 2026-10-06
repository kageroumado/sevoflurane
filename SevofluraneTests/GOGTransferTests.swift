import Foundation
import Synchronization
import Testing
@testable import Sevoflurane

/// The folder each gogdl transfer is pointed at, checked against a fake
/// gogdl that writes where gogdl 1.3.0 would: `download` into `--path`
/// joined with GOG's folder name, `update` and `repair` into `--path` itself.
struct GOGTransferTests {
    private static let folderName = "Nightsong"

    /// A gogdl stand-in that records each command and drops a file in the
    /// game folder that command works in.
    private final class FakeGOGDL: Sendable {
        let calls = Mutex<[[String]]>([])

        var client: GOG.Client {
            { [self] arguments, _ in
                calls.withLock { $0.append(arguments) }
                guard let directory = Self.gameDirectory(arguments) else { throw StoreFailure("no --path") }
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try Data().write(to: directory.appending(path: "\(arguments[0]).marker"))
                return StoreProcess.Result(status: 0, stdout: "", stderr: "")
            }
        }

        /// The game folder gogdl 1.3.0 works in for these arguments.
        static func gameDirectory(_ arguments: [String]) -> URL? {
            guard let flag = arguments.firstIndex(of: "--path"), flag + 1 < arguments.count else { return nil }
            let path = URL(fileURLWithPath: arguments[flag + 1])
            return arguments.first == "download" ? path.appending(path: folderName) : path
        }
    }

    @Test
    func `download, update and repair all work in the selected game's folder`() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "GOGTransferTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appending(path: Self.folderName)
        let sibling = root.appending(path: "Another Game")
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)

        let gogdl = FakeGOGDL()
        try await GOG.transfer("1207658924", .download(base: root), client: gogdl.client) { _ in }
        try await GOG.transfer("1207658924", .update(folder: game), client: gogdl.client) { _ in }
        try await GOG.transfer("1207658924", .repair(folder: game), client: gogdl.client) { _ in }

        let calls = gogdl.calls.withLock(\.self)
        #expect(calls.map(\.first) == ["download", "update", "repair"])
        for call in calls {
            let directory = try #require(FakeGOGDL.gameDirectory(call))
            #expect(directory.standardizedFileURL.path == game.standardizedFileURL.path)
        }
        let written = try FileManager.default.contentsOfDirectory(atPath: game.path).sorted()
        #expect(written == ["download.marker", "repair.marker", "update.marker"])
        #expect(try FileManager.default.contentsOfDirectory(atPath: sibling.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).sorted() == ["Another Game", Self.folderName])
    }

    @Test
    func `the arguments name the verb, the title and the folder`() {
        let folder = URL(fileURLWithPath: "/Games/GOG/Nightsong")
        #expect(GOG.arguments("42", .repair(folder: folder)) == [
            "repair", "42", "--platform", "windows", "--path", "/Games/GOG/Nightsong", "--lang", "en-US", "--skip-dlcs",
        ])
    }

    @Test
    func `a failing transfer throws the client's last word`() async {
        let client: GOG.Client = { _, _ in
            StoreProcess.Result(status: 1, stdout: "", stderr: "[DOWNLOAD] ERROR: no space left")
        }
        await #expect(throws: StoreFailure.self) {
            try await GOG.transfer("42", .update(folder: URL(fileURLWithPath: "/x")), client: client) { _ in }
        }
    }
}
