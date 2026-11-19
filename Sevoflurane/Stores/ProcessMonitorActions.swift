import AppKit
import Foundation
import Observation

/// What a row can be asked to do, and what it did.
@MainActor
@Observable
final class ProcessMonitorActions {
    let watch: StallWatch
    private(set) var note: String?

    init(watch: StallWatch) {
        self.watch = watch
    }

    /// Brings the process's own window forward, the same way a launch does.
    func bringToFront(_ process: StallWatch.Process) {
        Task(name: "Bring \(process.name) forward") {
            let front = await Activation().bringForward(
                pid: process.pid, describedAs: process.name,
            )
            note = front
                ? String(localized: "\(process.name) is frontmost.")
                : String(localized: "macOS declined to activate \(process.name).")
        }
    }

    /// Asks the process's whole tree to quit.
    ///
    /// `SIGTERM`, not `SIGKILL`: a game that can still save should get the
    /// chance, and the stall watchdog is what kills one that cannot answer.
    func terminate(_ process: StallWatch.Process) {
        let tree = ProcessUsage.tree(under: [process.pid])
        for pid in tree { kill(pid, SIGTERM) }
        note = String(localized: "Asked \(tree.count) processes under \(process.name) to quit.")
        EventLog.shared.log(.app, "process monitor: terminated \(process.name) (\(process.pid))")
    }

    /// Collects this game's report now, from the run it belongs to, without
    /// waiting for the run to end.
    func collectReports(_ process: StallWatch.Process) {
        guard let appID = process.appID,
              let record = watch.recorder?.openRecord(forApp: appID) else {
            note = String(localized: "\(process.name) has no active game run in Sevoflurane.")
            return
        }
        note = String(localized: "Collecting…")
        Task.detached(name: "Collect app \(appID)'s report") {
            let report = CrashCollector.collect(for: record)
            await MainActor.run {
                self.note = report.map {
                    String(localized: "Wrote \($0.manifest.sources.count) sources to \($0.directory.lastPathComponent).")
                } ?? String(localized: "Could not write a report.")
            }
        }
    }
}
