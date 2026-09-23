import Foundation
import Testing
@testable import Sevoflurane

/// Reading a log's last lines from its end.
struct LogTailTests {
    private func log(lines: Int, width: Int) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("logtail-\(UUID().uuidString).log")
        let text = (1 ... lines).map { "line \($0) " + String(repeating: "x", count: width) }
            .joined(separator: "\n") + "\n"
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test
    func `the last lines come back whole and in order`() throws {
        let url = try log(lines: 5000, width: 200)
        defer { try? FileManager.default.removeItem(at: url) }
        let tail = try #require(LogTail.lastLines(of: url, count: 3))
        #expect(tail.map { String($0.prefix(10)) } == ["line 4998 ", "line 4999 ", "line 5000 "])
    }

    @Test
    func `a file shorter than the ask comes back entire`() throws {
        let url = try log(lines: 4, width: 1)
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(LogTail.lastLines(of: url, count: 50)?.count == 4)
    }

    @Test
    func `a missing file is nil`() {
        #expect(LogTail.lastLines(of: URL(fileURLWithPath: "/nonexistent/sevo.log"), count: 5) == nil)
    }
}
