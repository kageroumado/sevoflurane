import Foundation
import Testing
@testable import Sevoflurane

/// The capability every native caller presents to the control ports. What
/// keeps another account out is the file's owner and mode, so those are what
/// these tests hold the loader to.
struct ControlTokenTests {
    private func scratch() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-token-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func mode(of url: URL) -> mode_t {
        var info = stat()
        lstat(url.path, &info)
        return info.st_mode & 0o777
    }

    @Test
    func `the first load makes a private directory and a private token`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        let token = try ControlToken.load(in: directory)
        #expect(token.count == ControlToken.byteCount * 2)
        #expect(token.allSatisfy { $0.isHexDigit && !$0.isUppercase })
        #expect(mode(of: directory) == 0o700)
        #expect(mode(of: directory.appendingPathComponent(ControlToken.fileName)) == 0o600)
        // Every later load, from any process, reads the same one.
        #expect(try ControlToken.load(in: directory) == token)
        // Only the token is left beside it.
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [ControlToken.fileName])
    }

    @Test
    func `two tokens are never the same`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try ControlToken.load(in: root.appendingPathComponent("A"))
        let second = try ControlToken.load(in: root.appendingPathComponent("B"))
        #expect(first != second)
    }

    @Test
    func `a token others can read is replaced, never used`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        let exposed = try ControlToken.load(in: directory)
        let file = directory.appendingPathComponent(ControlToken.fileName)
        #expect(chmod(file.path, 0o644) == 0)
        let replacement = try ControlToken.load(in: directory)
        #expect(replacement != exposed)
        #expect(mode(of: file) == 0o600)
    }

    @Test
    func `a directory opened to others is closed again`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        let token = try ControlToken.load(in: directory)
        #expect(chmod(directory.path, 0o755) == 0)
        #expect(try ControlToken.load(in: directory) == token)
        #expect(mode(of: directory) == 0o700)
    }

    @Test
    func `a malformed token is replaced`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        _ = try ControlToken.load(in: directory)
        let file = directory.appendingPathComponent(ControlToken.fileName)
        try Data("short".utf8).write(to: file)
        #expect(chmod(file.path, 0o600) == 0)
        let token = try ControlToken.load(in: directory)
        #expect(token.count == ControlToken.byteCount * 2)
    }

    @Test
    func `a link in the token's place is refused`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        _ = try ControlToken.load(in: directory)
        let file = directory.appendingPathComponent(ControlToken.fileName)
        let elsewhere = root.appendingPathComponent("elsewhere")
        try Data(String(repeating: "ab", count: ControlToken.byteCount).utf8).write(to: elsewhere)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: elsewhere)
        #expect(throws: ControlToken.Failure.notAFile(file.path)) {
            try ControlToken.load(in: directory)
        }
    }

    @Test
    func `a directory in the token's place is refused`() throws {
        let root = try scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("Control", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(ControlToken.fileName), withIntermediateDirectories: true,
        )
        #expect(throws: ControlToken.Failure.self) {
            try ControlToken.load(in: directory)
        }
    }

    @Test
    func `only this account's plain file with no group or world bits is usable`() {
        let me = getuid()
        #expect(ControlToken.judge(owner: me, mode: S_IFREG | 0o600, user: me) == .usable)
        #expect(ControlToken.judge(owner: me, mode: S_IFREG | 0o400, user: me) == .usable)
        #expect(ControlToken.judge(owner: me, mode: S_IFREG | 0o640, user: me) == .exposed)
        #expect(ControlToken.judge(owner: me, mode: S_IFREG | 0o604, user: me) == .exposed)
        #expect(ControlToken.judge(owner: me, mode: S_IFREG | 0o602, user: me) == .exposed)
        #expect(ControlToken.judge(owner: me + 1, mode: S_IFREG | 0o600, user: me) == .foreignOwner)
        #expect(ControlToken.judge(owner: 0, mode: S_IFREG | 0o600, user: me) == .foreignOwner)
        #expect(ControlToken.judge(owner: me, mode: S_IFLNK | 0o600, user: me) == .notAFile)
        #expect(ControlToken.judge(owner: me, mode: S_IFDIR | 0o700, user: me) == .notAFile)
        #expect(ControlToken.judge(owner: me, mode: S_IFIFO | 0o600, user: me) == .notAFile)
    }

    @Test
    func `each installation keeps its own token`() {
        #expect(ControlToken.directory.path.hasPrefix(AppIdentity.supportFolder.path + "/"))
    }
}
