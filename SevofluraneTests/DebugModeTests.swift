import Foundation
import Testing
@testable import Sevoflurane

/// Debug mode's file: the only thing a session leaves in the bottle, and the
/// only thing that can outlive one.
struct DebugModeTests {
    /// A prefix of its own per test, so nothing here can reach a real bottle.
    private func makePrefix() throws -> URL {
        let prefix = FileManager.default.temporaryDirectory
            .appending(path: "debug-mode-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        return prefix
    }

    @Test
    func `turning it on writes the file, turning it off deletes it`() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let file = DebugMode.envURL(prefix: prefix)

        DebugMode.turnOn(prefix: prefix)
        #expect(DebugMode.isWritten(prefix: prefix))
        let text = try String(contentsOf: file, encoding: .utf8)
        // Every key the engine and the renderer read, and the channels the
        // diagnostics switch sets — the file is the whole engine half.
        for key in [
            "WINEDEBUG=\(WineLog.levelOne)",
            "DXMT_LOG_LEVEL=error",
            "DXMT_LOG_PATH=",
            "SEVO_PRESENTATION_LOG=1",
            "SEVO_PRESENTER_LOG=1",
            "SEVO_GFX_LOG=1",
        ] {
            #expect(text.contains(key), "missing \(key) in:\n\(text)")
        }
        // The renderer writes one file per executable into a directory, so the
        // directory has to be there before it looks.
        #expect(FileManager.default.fileExists(
            atPath: DebugMode.rendererLogDirectory(prefix: prefix).path,
        ))

        DebugMode.turnOff(prefix: prefix)
        #expect(!DebugMode.isWritten(prefix: prefix))
    }

    /// The engine reads `KEY=` as an unset, so a value that is written must
    /// carry one: a stray empty key would silence the channels the bottle's
    /// own file just set.
    @Test
    func `every line is a key with a value`() {
        for line in DebugMode.lines() {
            let parts = line.split(separator: "=", maxSplits: 1)
            #expect(parts.count == 2, "not a key and a value: \(line)")
            #expect(!(parts.last ?? "").isEmpty, "empty value: \(line)")
        }
    }

    @Test
    func `a file a killed session left behind is cleared, and only then`() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }

        #expect(DebugMode.clearStale(prefix: prefix) == false)
        DebugMode.turnOn(prefix: prefix)
        #expect(DebugMode.clearStale(prefix: prefix) == true)
        #expect(!DebugMode.isWritten(prefix: prefix))
        #expect(DebugMode.clearStale(prefix: prefix) == false)
    }

    /// The bottle's own file is a separate document underneath this one; a
    /// session that ends must leave it exactly as it found it.
    @Test
    func `the bottle's file is untouched by either direction`() throws {
        let prefix = try makePrefix()
        defer { try? FileManager.default.removeItem(at: prefix) }
        let bottle = prefix.appending(path: ".sevo/bottle.env")
        try FileManager.default.createDirectory(
            at: bottle.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        let original = "# written by hand\nWINEDEBUG=-all\n"
        try original.write(to: bottle, atomically: true, encoding: .utf8)

        DebugMode.turnOn(prefix: prefix)
        DebugMode.turnOff(prefix: prefix)

        #expect(try String(contentsOf: bottle, encoding: .utf8) == original)
    }
}
