import AppKit
import Propofol
import SwiftUI

/// The window a bug report is made from: recent runs, and the selected run's
/// record, frame rate, findings and ``KnownFailures`` match.
@MainActor
final class ReportWindows {
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
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
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.window = nil
                if let observer = self?.closeObserver {
                    NotificationCenter.default.removeObserver(observer)
                    self?.closeObserver = nil
                }
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

// MARK: - The view

struct ReportView: View {
    /// Opens the steps for a useful report; absent in the gallery.
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
                if let reported = store.reported[run.id] {
                    Text("Reported: \(reported.verdict.displayName)")
                        .font(.caption)
                        .foregroundStyle(reported.refused == nil ? Color.accentColor : .orange)
                }
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
                    if let report = store.report {
                        RunReportCard(model: report) { store.reloadReported() }
                    }
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
        facts.append(("Enhanced sync (msync+)", run.msync ? "on" : "off"))
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

/// The run's frame rate, when something counted the frames.
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

    /// The average against the 1 % low, which says whether a run was smooth.
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
                // By position: Wine's trail repeats the same exception line.
                ForEach(findings.enumerated(), id: \.offset) { _, finding in
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
