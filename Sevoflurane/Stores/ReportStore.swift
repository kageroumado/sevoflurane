import AppKit
import Foundation
import Observation

/// What the window shows and the two things it can do with it.
@MainActor
@Observable
final class ReportStore {
    /// How many runs the list goes back over, more than a month of play.
    static let recentRuns = 50

    private(set) var runs: [RunRecord] = []
    var selected: RunRecord.ID?
    private(set) var findings: [String] = []
    /// Where the selected run's collected report sits, when it has one.
    private(set) var reportPath: URL?
    private(set) var writing = false
    private(set) var note: String?
    /// "How did it go?" for the selected run.
    private(set) var report: RunReportModel?
    /// Every run's standing in the community database, by run id, for the list's rows.
    private(set) var reported: [String: StatsStore.Reported] = [:]

    var run: RunRecord? {
        runs.first { $0.id == selected }
    }

    func refresh() {
        runs = RunLog.recent(Self.recentRuns).reversed()
        if selected == nil || run == nil { selected = runs.first?.id }
        reloadReported()
        reload()
    }

    /// Rereads the ledger of reported runs, which `sevo report` also writes.
    func reloadReported() {
        reported = Dictionary(StatsStore.readReported().map { ($0.runID, $0) }, uniquingKeysWith: { _, last in last })
    }

    /// Reads the selected run's report; disk work, so called on selection only.
    func reload() {
        guard let run else {
            findings = []
            reportPath = nil
            report = nil
            return
        }
        report = RunReportModel(record: run)
        reportPath = CrashCollector.report(for: run)
        findings = reportPath.map { path in
            path.pathExtension == "xz" ? [String(localized: "The report was compressed at level 2.")]
                : CrashCollector.findings(in: path)
        } ?? []
    }

    /// The failure this project already knows, when it recognizes this run.
    var known: KnownFailures.Entry? {
        run.flatMap(KnownFailures.match)
    }

    // MARK: - What the zip holds

    /// Says what the zip holds, shown before either button.
    static let contentsSentence =
        "The zip holds this run's record, the app's and Wine's logs, the game's own "
            + "crash logs, Steam's logs and a doctor report. Paths, account names, "
            + "Steam ids and persona names are taken out of every one of them."

    /// The clipboard text beside the zip, for pasting into an issue.
    func manifest(zip: URL?) -> String {
        var lines = ["Sevoflurane report"]
        if let run { lines.append(run.summary) }
        if let zip { lines.append("zip: \(Redaction.apply(to: zip))") }
        lines.append("")
        lines.append("Removed from every file:")
        lines += ReportStripper.removed.map { "  · \($0)" }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Actions

    /// Writes the zip through the bundled CLI, the same report the terminal
    /// makes, and copies the manifest.
    func copyAllLogs() {
        guard !writing else { return }
        writing = true
        note = nil
        // The zip is this run's, as the card says: no other game's records.
        let scope = run.map { ["--run", $0.id] } ?? []
        Task(name: "Write the report zip") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
            let result = await Subprocess.run(
                helper.path, ["diag", "save", "--steam-logs"] + scope, capture: .combined,
                timeout: .seconds(120),
            )
            writing = false
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            guard result.status == 0, path.hasSuffix(".zip") else {
                note = String(localized: "Could not write the report: \(result.output.suffix(200))")
                return
            }
            let zip = URL(filePath: path)
            let board = NSPasteboard.general
            board.clearContents()
            board.setString(manifest(zip: zip), forType: .string)
            note = String(localized: "Wrote \(zip.lastPathComponent) to the Desktop. The manifest is on the clipboard.")
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        }
    }

    /// Opens a prefilled issue; the person attaches the zip.
    func openAnIssue() {
        guard let run, let url = Self.issueURL(for: run) else { return }
        EventLog.shared.log(.window, "report window: opening an issue for app \(run.appid)")
        NSWorkspace.shared.open(url)
    }

    /// The new-issue page with the template already filled in.
    static func issueURL(for run: RunRecord) -> URL? {
        var components = URLComponents(string: issuesURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: title(for: run)),
            URLQueryItem(name: "body", value: body(for: run)),
        ]
        return components?.url
    }

    static let issuesURL = "https://github.com/kageroumado/sevoflurane/issues/new"

    /// `Demons Roots: crashed in opengl32.dll+0xd7691 on r2/DXMT`.
    static func title(for run: RunRecord) -> String {
        let game = run.name ?? String(localized: "App \(String(run.appid))")
        let engine = "\(run.engine)/\(run.renderer)"
        guard let crash = run.crash else {
            let ending = run.exit.map { "ended \($0.kind.rawValue)" } ?? "did not finish"
            return "\(game): \(ending) on \(engine)"
        }
        let site = crash.module.map { "\($0)\(crash.address.map { " + \($0)" } ?? "")" }
            ?? crash.address ?? crash.code
        return "\(game): crashed in \(site) on \(engine)"
    }

    /// The issue body: the record's level-0 lines.
    static func body(for run: RunRecord) -> String {
        var lines = ["\(run.summary)", ""]
        lines.append("engine: \(run.engine) · renderer: \(run.rendererLabel) · runner: \(run.runner)")
        lines.append("macOS \(run.macos)\(run.chip.map { " · \($0)" } ?? "")")
        if let arch = run.arch { lines.append("game: \(arch)-bit\(run.runtime.map { " \($0)" } ?? "")") }
        if let windowAfter = run.windowAfterSeconds {
            lines.append("first window after \(windowAfter) s")
        } else {
            lines.append("no window ever appeared")
        }
        if let fps = run.fps {
            lines.append("fps: \(fps.avg) average, 1 % low \(fps.low1), \(fps.samples) samples")
            if let gameplay = fps.gameplay {
                let rates = gameplay.frameTimes.map { "\($0.avg) average, 1 % low \($0.low1), p99 \($0.p99) ms" }
                    ?? "too short to measure"
                lines.append("gameplay: \(gameplay.seconds) s from \(gameplay.from) s — \(rates)")
            }
        }
        if let display = run.display {
            lines.append("display: \(FrameTrace.line(for: display))")
        }
        if let crash = run.crash {
            lines.append(
                "exception \(crash.code)\(crash.module.map { " in \($0)" } ?? "")"
                    + (crash.address.map { " at \($0)" } ?? ""),
            )
        }
        for stall in run.stalls ?? [] {
            lines.append(
                "stall at \(stall.at) s for \(stall.duration) s"
                    + (stall.unwedged.map { " — \($0)" } ?? " — nothing helped"),
            )
        }
        for note in run.notes ?? [] { lines.append("renderer: \(note)") }
        if let known = KnownFailures.match(run) { lines += ["", known.summary] }
        lines += ["", "Attached: the Sevoflurane report zip.", "", Self.contentsSentence]
        return lines.joined(separator: "\n")
    }

    /// Reveals the collected report, or the reports directory.
    func lookInside() {
        let target = reportPath ?? CrashCollector.root
        try? FileManager.default.createDirectory(
            at: CrashCollector.root, withIntermediateDirectories: true,
        )
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}
