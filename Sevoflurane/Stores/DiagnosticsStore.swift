import AppKit
import Foundation
import Observation

/// What Settings › Diagnostics shows and changes: the recording level and the
/// collected reports.
@MainActor
@Observable
final class DiagnosticsStore {
    private(set) var level: DiagnosticLevel
    private(set) var reportCount = 0
    private(set) var reportBytes = 0

    init() {
        level = DiagnosticLevel.current
    }

    /// Rereads the level and the reports folder.
    func refresh() {
        level = DiagnosticLevel.current
        let reports = CrashCollector.reports()
        reportCount = reports.count
        reportBytes = reports.reduce(0) { $0 + $1.bytes }
    }

    /// Stores the level and keeps what the store answers, which a failed
    /// write leaves where it was.
    func setLevel(_ wanted: DiagnosticLevel) {
        level = DiagnosticLevel.set(wanted)
        EventLog.shared.log(.app, "diagnostics \(level.summary)")
    }

    /// Shows the reports folder in the Finder, making it first when no report
    /// has been collected.
    func revealReports() {
        let root = CrashCollector.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}
