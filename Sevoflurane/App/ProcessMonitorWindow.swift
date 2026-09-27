import AppKit
import Propofol
import SwiftUI

/// Every process this app owns, in one table.
///
/// It is the stall watchdog's own sampler with a window in front of it —
/// ``StallWatch/processes`` is what the rows are, so what the watchdog decides
/// and what a person sees can never disagree. It is a stats bar over a list,
/// each row saying what the thing is and what it is doing, and the actions
/// that apply to one row on that row.
@MainActor
final class ProcessMonitorWindows {
    private var window: NSWindow?
    private var closeObserver: (any NSObjectProtocol)?
    private let watch: StallWatch

    init(watch: StallWatch) {
        self.watch = watch
    }

    func show() {
        ActivationPolicy.becomeRegular()
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        EventLog.shared.log(.window, "process monitor: opened")
        let view = ProcessMonitorView(watch: watch)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = InterfaceCopy.localized("Processes")
        window.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        window.setContentSize(NSSize(width: 820, height: 480))
        window.minSize = NSSize(width: 640, height: 320)
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

struct ProcessMonitorView: View {
    let watch: StallWatch

    @State private var actions: ProcessMonitorActions
    @State private var selection: pid_t?

    init(watch: StallWatch) {
        self.watch = watch
        _actions = State(initialValue: ProcessMonitorActions(watch: watch))
    }

    var body: some View {
        VStack(spacing: 0) {
            statsBar
            table
            footer
        }
    }

    // MARK: - The bar over it

    private var statsBar: some View {
        HStack(spacing: Theme.Space.lg) {
            ForEach(counts, id: \.label) { count in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(count.value)").font(.title3.monospacedDigit())
                    Text(InterfaceCopy.localized(count.label)).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(footprint).font(.title3.monospacedDigit())
                Text("memory").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(Theme.Space.lg)
    }

    private var counts: [(label: String, value: Int)] {
        [
            ("processes", watch.processes.count),
            ("games", watch.processes.count { $0.role == .game || $0.role == .gameChild }),
            ("stalled", watch.processes.count { $0.state == .stalled }),
            ("stopped", watch.processes.count { $0.state == .stopped }),
        ]
    }

    private var footprint: String {
        Int64(watch.processes.reduce(0) { $0 + $1.footprintBytes }).formatted(.byteCount(style: .memory))
    }

    // MARK: - The table

    private var table: some View {
        Table(watch.processes, selection: $selection) {
            TableColumn("PID") { Text("\($0.pid)").monospacedDigit() }
                .width(60)
            TableColumn("Program", value: \.name)
            TableColumn("Role") { Text(InterfaceCopy.localized($0.role.title)) }
                .width(90)
            TableColumn("CPU") { process in
                Text("\(Int(process.cpuShare * 100)) %").monospacedDigit()
            }
            .width(60)
            TableColumn("Memory") { process in
                Text(Int64(process.footprintBytes).formatted(.byteCount(style: .memory)))
                    .monospacedDigit()
            }
            .width(90)
            TableColumn("Frames") { process in
                Text(process.presents.map { "\($0)" } ?? "—").monospacedDigit()
            }
            .width(80)
            TableColumn("State") { process in
                if process.holdsOneCore {
                    StateChip(text: InterfaceCopy.localized("one core at 100 %"), tint: .orange)
                        .help("This game has held exactly one core for over a minute. A game at rest on a menu should use far less: it is usually a busy loop in the game, and sometimes a sign that something it waits for never arrives.")
                } else {
                    StateChip(text: InterfaceCopy.localized(process.state.rawValue), tint: process.state.tint)
                }
            }
            .width(min: 90, ideal: 130)
        }
        .contextMenu(forSelectionType: pid_t.self) { selected in
            rowActions(for: selected)
        }
        .tableStyle(.inset)
    }

    @ViewBuilder
    private func rowActions(for selected: Set<pid_t>) -> some View {
        if let process = watch.processes.first(where: { selected.contains($0.pid) }) {
            Button("Bring to front") { actions.bringToFront(process) }
            Button("Collect reports now") { actions.collectReports(process) }
            Divider()
            Button("Terminate", role: .destructive) { actions.terminate(process) }
        }
    }

    // MARK: - The bar under it

    private var footer: some View {
        HStack(spacing: Theme.Space.sm) {
            Text(actions.note ?? InterfaceCopy.localized("Right-click a row for available actions."))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer()
            if let process = selected {
                Button("Bring to front") { actions.bringToFront(process) }
                Button("Collect reports") { actions.collectReports(process) }
                Button("Terminate") { actions.terminate(process) }
            }
        }
        .padding(Theme.Space.md)
    }

    private var selected: StallWatch.Process? {
        watch.processes.first { $0.pid == selection }
    }
}

extension StallWatch.Role {
    /// What a role is called in front of a person.
    var title: String {
        switch self {
        case .client: "client"
        case .helper: "helper"
        case .game: "game"
        case .gameChild: "game child"
        case .driver: "driver"
        }
    }
}

extension StallWatch.State {
    /// The chip's color: a stall is the one worth looking at.
    var tint: Color {
        switch self {
        case .running: .green
        case .idle: .secondary
        case .stopped: .orange
        case .stalled, .notAnswering: .red
        }
    }
}
