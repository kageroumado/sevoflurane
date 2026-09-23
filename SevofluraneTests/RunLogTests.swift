import Foundation
import Testing
@testable import Sevoflurane

/// Reading runs back across the months the log keeps.
struct RunLogTests {
    @Test
    func `recent runs span a month that has been compressed`() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("runlog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let older = [Self.record(at: "2026-07-01T10:00:00Z"), Self.record(at: "2026-07-02T10:00:00Z")]
        let lines = try older.map { try JSONEncoder().encode($0) + Data("\n".utf8) }.reduce(Data(), +)
        let compressed = try (lines as NSData).compressed(using: .zlib) as Data
        try compressed.write(to: root.appendingPathComponent("2026-07.jsonl.z"))
        RunLog.append(Self.record(at: "2026-09-01T10:00:00Z"), in: root)

        let recent = RunLog.recent(3, in: root)
        #expect(recent.map(\.t) == ["2026-07-01T10:00:00Z", "2026-07-02T10:00:00Z", "2026-09-01T10:00:00Z"])
    }

    private static func record(at time: String) -> RunRecord {
        RunRecord(
            t: time,
            appid: 508_440,
            engine: "dormison-r4",
            renderer: "dxmt",
            runner: "wine",
            windows: "fixed",
            msync: true,
            runtime: "unity",
            macos: "26.5.2",
            windowAfterSeconds: nil,
            exit: nil,
            notes: nil,
            host: RunRecord.Host(thermal: "nominal", load: 1),
        )
    }
}
