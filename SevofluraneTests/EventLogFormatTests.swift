import Foundation
import Testing
@testable import Sevoflurane

/// One timestamp in the log file. A reader sorts it by time and greps it for a
/// moment; a second format, or a second time zone, breaks both.
struct EventLogFormatTests {
    /// `2026-09-09 00:48:41.612 [app] …` — local time, milliseconds, colons.
    private var stamped: Regex<Substring> {
        /^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[/
    }

    @Test
    func `every line of a written log carries the same stamp`() throws {
        let url = FileManager.default.temporaryDirectory
            .appending(path: "event-log-format-\(UUID().uuidString).log")
        var written = ""
        for category in [EventLog.Category.client, .window, .app, .setup] {
            written += EventLog.line(category, "\(category.rawValue) said something")
        }
        // The exception path writes several lines under one moment, stack
        // frames included; every one of them is a line of the same file.
        let moment = Date(timeIntervalSince1970: 1_788_932_921)
        for frame in ["ObjC exception thrown on main thread — a reason", "    0   AppKit  0x1"] {
            written += EventLog.line(.app, frame, at: moment)
        }
        try written.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }

        let lines = try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 6)
        for line in lines {
            #expect(line.firstMatch(of: stamped) != nil, "unstamped line: \(line)")
        }
    }

    @Test
    func `the stamp is local time, not GMT`() {
        let moment = Date(timeIntervalSince1970: 1_788_932_921)
        let line = EventLog.line(.app, "a message", at: moment)
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let hour = local.component(.hour, from: moment)
        let expected = String(format: "%02d:", hour)
        #expect(line.contains(" \(expected)"))
    }
}

/// The sidecar an ObjC exception leaves beside the log. Its name is the
/// contract the diagnostics bundle globs for, and its fields are what a crash
/// report cannot say: which window was key, and what the app had just been
/// doing.
struct ExceptionReportTests {
    @Test
    func `the sidecar sits beside the log, one file per throw`() {
        let moment = Date(timeIntervalSince1970: 1_788_932_921)
        let url = ExceptionReport.fileURL(at: moment)
        #expect(url.lastPathComponent == "Sevoflurane-exception-1788932921.json")
        #expect(url.deletingLastPathComponent() == EventLog.fileURL.deletingLastPathComponent())
    }

    @Test
    func `the report round-trips through JSON`() throws {
        let report = ExceptionReport(
            time: EventLog.stamp(Date(timeIntervalSince1970: 1_788_932_921)),
            name: "NSGenericException",
            reason: "Unable to activate constraint",
            thread: "main thread",
            keyWindow: "Settings (settings)",
            stack: ["0   AppKit  0x1", "1   SwiftUI  0x2"],
            recent: ["[window] settings: showing Engine"],
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let decoded = try JSONDecoder().decode(
            ExceptionReport.self, from: encoder.encode(report),
        )
        #expect(decoded.keyWindow == "Settings (settings)")
        #expect(decoded.stack.count == 2)
        #expect(decoded.recent.first == "[window] settings: showing Engine")
    }
}
