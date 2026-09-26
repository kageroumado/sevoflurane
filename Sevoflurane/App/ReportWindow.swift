import AppKit
import Propofol
import SwiftUI

/// The window a bug report is made from (`Docs/diagnostics-plan.md`).
///
/// The last runs down one side, each one line: the game, what it ran on, how
/// long it lasted, how it ended. Pick one and the other side says everything
/// the app knows about it — the record, its frame rate when something counted
/// the frames, the errors its collected report holds, and the sentence
/// ``KnownFailures`` has for it when this project has seen that failure before.
///
/// Two buttons: one writes the zip to the Desktop and puts what is in it on
/// the clipboard, the other opens a prefilled issue. Before either, one
/// sentence says what the zip holds and what was taken out, with a button to
/// go and look.
@MainActor
final class ReportWindows {
    private var window: NSWindow?
    /// Opens Settings › Diagnostics on the steps for a useful report.
    var showGuide: (() -> Void)?

    func show() {
        ActivationPolicy.becomeRegular()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        EventLog.shared.log(.window, "report window: opened")
        let window = NSWindow(
            contentViewController: NSHostingController(rootView: ReportView(showGuide: showGuide)),
        )
        window.title = InterfaceCopy.localized("Reports")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 860, height: 560))
        window.minSize = NSSize(width: 680, height: 420)
        window.isRestorable = false
        self.window = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// What the window shows and the two things it can do with it.
@MainActor
@Observable
final class ReportStore {
    /// How many runs the list goes back over. A month of play is fewer than
    /// this, and nobody reports a bug from further back than that.
    static let recentRuns = 50

    private(set) var runs: [RunRecord] = []
    var selected: RunRecord.ID?
    private(set) var findings: [String] = []
    /// Where the selected run's collected report sits, when it has one.
    private(set) var reportPath: URL?
    private(set) var writing = false
    private(set) var note: String?

    var run: RunRecord? {
        runs.first { $0.id == selected }
    }

    func refresh() {
        runs = RunLog.recent(Self.recentRuns).reversed()
        if selected == nil || run == nil { selected = runs.first?.id }
        reload()
    }

    /// Reads what the selected run's report holds. Called when the selection
    /// moves rather than per body evaluation: it is disk work.
    func reload() {
        guard let run else {
            findings = []
            reportPath = nil
            return
        }
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

    /// The sentence shown before either button, so nobody sends a file
    /// without being told what is in it.
    static let contentsSentence =
        "The zip holds this run's record, the app's and Wine's logs, the game's own "
            + "crash logs, Steam's logs and a doctor report. Paths, account names, "
            + "Steam ids and persona names are taken out of every one of them."

    /// What goes on the clipboard beside the zip: what it is, what is in it,
    /// and what was removed — the text a person pastes into an issue.
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

    /// Writes the zip through the bundled CLI, so the app and the terminal
    /// produce the same report, then puts the manifest on the clipboard.
    func copyAllLogs() {
        guard !writing else { return }
        writing = true
        note = nil
        Task(name: "Write the report zip") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
            let result = await Subprocess.run(
                helper.path, ["diag", "save", "--steam-logs"], capture: .combined,
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

    /// Opens a new issue with the title and body already filled in. The zip
    /// cannot ride in a URL, so the body names it and the person attaches it.
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

    /// `Demons Roots: crashed in opengl32.dll+0xd7691 on r2/DXMT` — the game,
    /// where it died, and what it was running on.
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

    /// The level-0 lines, which is everything the record says and nothing it
    /// does not.
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

    /// Opens the collected report, or the directory reports live in when this
    /// run has none.
    func lookInside() {
        let target = reportPath ?? CrashCollector.root
        try? FileManager.default.createDirectory(
            at: CrashCollector.root, withIntermediateDirectories: true,
        )
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }
}

/// A run record's identity for the list: the moment it began and the app,
/// which no two runs share.
extension RunRecord: Identifiable {
    var id: String {
        "\(appid)-\(t)"
    }
}

// MARK: - The view

struct ReportView: View {
    /// Opens the steps for a useful report. Absent in the gallery, where no
    /// second window opens.
    var showGuide: (() -> Void)?
    @State private var store = ReportStore()

    var body: some View {
        NavigationSplitView {
            runList
        } detail: {
            detail
        }
        .navigationSplitViewStyle(.balanced)
        .task { store.refresh() }
        .onChange(of: store.selected) { _, _ in store.reload() }
    }

    private var runList: some View {
        List(store.runs, selection: $store.selected) { run in
            VStack(alignment: .leading, spacing: 2) {
                Text(run.name ?? String(localized: "App \(String(run.appid))"))
                    .font(.body)
                Text(run.displayOutcome)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            .padding(.vertical, 2)
            .tag(run.id)
        }
        .navigationTitle("Runs")
        .overlay {
            if store.runs.isEmpty {
                ContentUnavailableView {
                    Label("No runs yet", systemImage: "gamecontroller")
                } description: {
                    Text("Every game you launch appears here. See Settings › Diagnostics for how to record a useful run.")
                } actions: {
                    if let showGuide {
                        Button("Making a Useful Report…") { showGuide() }
                    }
                }
            }
        }
    }

    @ViewBuilder private var detail: some View {
        if let run = store.run {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Space.lg) {
                    RunSummaryCard(run: run, known: store.known)
                    FrameRateCard(fps: run.fps)
                    FindingsCard(findings: store.findings, hasReport: store.reportPath != nil)
                    shareCard
                }
                .padding(Theme.Space.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(run.name ?? String(localized: "App \(String(run.appid))"))
        } else {
            ContentUnavailableView("Pick a run", systemImage: "list.bullet.rectangle")
        }
    }

    private var shareCard: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text("Share this run")
                .font(.headline)
            Text(InterfaceCopy.localized(ReportStore.contentsSentence))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.Space.sm) {
                Button("Look inside") { store.lookInside() }
                Spacer()
                Button(store.writing ? "Writing…" : "Copy all logs") { store.copyAllLogs() }
                    .disabled(store.writing)
                Button("Open an issue") { store.openAnIssue() }
                    .buttonStyle(.borderedProminent)
            }
            if let note = store.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.lg)
        .glassCard()
    }
}

/// What the record says, and the sentence this project has for it.
private struct RunSummaryCard: View {
    let run: RunRecord
    let known: KnownFailures.Entry?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(run.displaySummary)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
            LazyVGrid(
                columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                alignment: .leading,
                spacing: Theme.Space.sm,
            ) {
                ForEach(facts, id: \.label) { fact in
                    LabeledContent(InterfaceCopy.localized(fact.label)) {
                        Text(InterfaceCopy.localized(fact.value)).foregroundStyle(.secondary)
                    }
                }
            }
            if let known { knownFailure(known) }
        }
        .padding(Theme.Space.lg)
        .glassCard()
    }

    private func knownFailure(_ entry: KnownFailures.Entry) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(InterfaceCopy.localized(entry.summary), systemImage: "lightbulb")
                .fixedSize(horizontal: false, vertical: true)
            if let fix = entry.fix {
                Text(InterfaceCopy.localized(fix))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, Theme.Space.xs)
    }

    /// The record's own fields, in the order someone reads them.
    private var facts: [(label: String, value: String)] {
        var facts = [
            ("Engine", run.engine),
            ("Renderer", run.displayRendererLabel),
            ("Runner", run.runner),
            ("Windows", run.windows),
            ("macOS", run.macos),
        ]
        if let chip = run.chip { facts.append(("Chip", chip)) }
        if let arch = run.arch { facts.append(("Address width", "\(arch)-bit")) }
        if let runtime = run.runtime { facts.append(("Built on", runtime)) }
        if let d3dmetal = run.d3dmetal { facts.append(("D3DMetal", d3dmetal)) }
        facts.append(("Enhanced sync", run.msync ? "on" : "off"))
        if let gameMode = run.gameMode { facts.append(("Game Mode", gameMode ? "on" : "off")) }
        if let window = run.windowAfterSeconds {
            facts.append(("First window", "\(window) s"))
        } else {
            facts.append(("First window", "never drew"))
        }
        if let energy = run.energy {
            facts.append(("Energy", "\(energy.nanojoules / 1_000_000) mJ"))
            facts.append(("On P-cores", "\(Int(energy.pCoreShare * 100)) %"))
        }
        if let crash = run.crash {
            facts.append(("Exception", crash.code))
            if let module = crash.module { facts.append(("In", module)) }
        }
        return facts
    }
}

/// The run's frame rate when something counted the frames, and a plain
/// sentence when nothing did.
private struct FrameRateCard: View {
    let fps: RunRecord.FrameRate?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Frame rate")
                .font(.headline)
            if let fps {
                HStack(spacing: Theme.Space.lg) {
                    reading("Average", "\(fps.avg)")
                    reading("1 % low", "\(fps.low1)")
                    reading("Samples", "\(fps.samples)")
                }
                bars(fps)
            } else {
                Text("Nothing counted this run's frames. A game with no Metal layer has no counter, and the driver's counter reaches records from the engine that carries it.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.lg)
        .glassCard()
    }

    private func reading(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title3.monospacedDigit())
            Text(InterfaceCopy.localized(label)).font(.caption).foregroundStyle(.secondary)
        }
    }

    /// The average against the one-per-cent low, which is the comparison that
    /// says whether a run was smooth or merely fast on average.
    private func bars(_ fps: RunRecord.FrameRate) -> some View {
        let ceiling = max(fps.avg, fps.low1, 1)
        return VStack(alignment: .leading, spacing: 4) {
            bar(fps.avg / ceiling, tint: .accentColor)
            bar(fps.low1 / ceiling, tint: .orange)
        }
        .frame(height: 24)
    }

    private func bar(_ fraction: Double, tint: Color) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(tint).frame(width: geometry.size.width * fraction)
            }
        }
    }
}

/// What the collected report holds, or why there is none.
private struct FindingsCard: View {
    let findings: [String]
    let hasReport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text("Report contents")
                .font(.headline)
            if findings.isEmpty {
                Text(InterfaceCopy.localized(hasReport
                    ? "A report was collected and nothing in it names an error."
                    : "No report was collected: this run ended normally and diagnostics were off. Settings › Diagnostics collects one after every run."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(findings, id: \.self) { finding in
                    Text(finding)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(Theme.Space.lg)
        .glassCard()
    }
}
