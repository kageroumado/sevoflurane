import Foundation
import Testing
@testable import Sevoflurane

/// The dock shim's chronicle, read back — the lines are exactly as the shim
/// writes them (`sevo_dock_shim.c`, `chronicle`).
struct WineChronicleTests {
    @Test
    func `a process line names the executable that has no window yet`() {
        let entry = WineChronicle.parse("00:28:14.358 armed pid=2768 TotallyAccurateBattleSimulator.exe  \"\" 0x0")
        #expect(entry?.verb == .armed)
        #expect(entry?.pid == 2768)
        #expect(entry?.executable == "TotallyAccurateBattleSimulator.exe")
    }

    @Test
    func `a window line keeps the executable apart from the class, title and size`() {
        let entry = WineChronicle.parse(
            "00:34:27.399 passed pid=11845 The Cat Games.exe WineWindow \"The Cat Games\" 111x33",
        )
        #expect(entry?.verb == .passed)
        #expect(entry?.pid == 11845)
        #expect(entry?.executable == "The Cat Games.exe")
    }

    @Test
    func `the driver's own subclass is a class name like any other`() {
        let entry = WineChronicle.parse(
            "21:09:23.333 passed pid=51985 Subnautica2-Win64-Shipping.exe "
                + "NSKVONotifying_WineWindow \"SN2  \" 2568x1474",
        )
        #expect(entry?.executable == "Subnautica2-Win64-Shipping.exe")
    }

    @Test
    func `lines that are not the shim's are dropped`() {
        #expect(WineChronicle.parse("") == nil)
        #expect(WineChronicle.parse("00:28:14.358 landed pid=1 game.exe  \"\" 0x0") == nil)
        #expect(WineChronicle.parse("00:28:14.358 armed 2768 game.exe  \"\" 0x0") == nil)
        #expect(WineChronicle.parse("wine: could not load ntdll") == nil)
    }

    @Test
    func `a tail reads only what was appended after it started`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WineChronicleTests-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "00:00:01.000 armed pid=1 before.exe  \"\" 0x0\n".write(
            to: url, atomically: true, encoding: .utf8,
        )

        let tail = WineChronicleTail(url: url)
        #expect(tail.newEntries().isEmpty)

        try Self.append("00:00:02.000 armed pid=2 game.exe  \"\" 0x0\n", to: url)
        #expect(tail.newEntries().map(\.executable) == ["game.exe"])
        #expect(tail.newEntries().isEmpty)
    }

    /// The shim writes a line per open, but a read can still land inside one.
    @Test
    func `a half-written line is held until its newline arrives`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WineChronicleTests-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let tail = WineChronicleTail(url: url)

        try Self.append("00:00:02.000 armed pid=2 half.e", to: url)
        #expect(tail.newEntries().isEmpty)
        try Self.append("xe  \"\" 0x0\n00:00:03.000 shaped pid=2 half.exe  \"\" 0x0\n", to: url)
        #expect(tail.newEntries().map(\.verb) == [.armed, .shaped])
    }

    /// A rotated log is shorter than what has already been read from it.
    @Test
    func `a truncated log is read from its start again`() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WineChronicleTests-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        try "00:00:01.000 armed pid=1 first.exe  \"\" 0x0\n".write(
            to: url, atomically: true, encoding: .utf8,
        )
        let tail = WineChronicleTail(url: url)

        try "00:00:02.000 armed pid=2 b.exe  \"\" 0x0\n".write(
            to: url, atomically: true, encoding: .utf8,
        )
        #expect(tail.newEntries().map(\.executable) == ["b.exe"])
    }

    private static func append(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }
}
