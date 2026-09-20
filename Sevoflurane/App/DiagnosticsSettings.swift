import AppKit
import Propofol
import SwiftUI

/// Settings › Diagnostics: how much a run is asked to say about itself, where
/// what it says is kept, and how much of the disk that is allowed to be.
///
/// The level reaches games at their next launch through the bottle's env
/// files, so nothing here needs Steam restarted. Level two takes itself off
/// after one game, which the pane says rather than leaving someone to
/// discover it.
struct DiagnosticsSettings: View {
    let highlighted: SettingsAnchor?
    /// Opens the report window. Absent in the gallery, where no window opens.
    var showReports: (() -> Void)?

    @State private var level = DiagnosticLevel.current
    @State private var reportBytes = 0

    var body: some View {
        Form {
            levelSection
            reportsSection
            capsSection
        }
        .formStyle(.grouped)
        .task { refresh() }
    }

    // MARK: - The level

    private var levelSection: some View {
        Section {
            Picker("Record", selection: levelBinding) {
                ForEach(DiagnosticLevel.allCases, id: \.self) { level in
                    Text(level.title).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .highlightable(.diagnosticsLevel, highlighted: highlighted)
            Text(level.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Wine channels") {
                Text(level.channels())
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            DebugModeRow()
                .highlightable(.diagnosticsDebugMode, highlighted: highlighted)
        } header: {
            Text("Recording")
        } footer: {
            Text("A level reaches each game the next time it is launched. "
                + "Debug mode restarts Steam, and ends when Sevoflurane quits.")
        }
    }

    private var levelBinding: Binding<DiagnosticLevel> {
        Binding(
            get: { level },
            set: { wanted in
                level = DiagnosticLevel.set(wanted)
                EventLog.shared.log(.app, "diagnostics \(level.summary)")
            },
        )
    }

    // MARK: - Where it goes

    private var reportsSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Run reports")
                    Text(reportsDetail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Show in Finder") { reveal() }
                if let showReports {
                    Button("Open…") { showReports() }
                }
            }
            .highlightable(.diagnosticsReports, highlighted: highlighted)
            SaveDiagnosticsRow()
                .highlightable(.diagnosticsSave, highlighted: highlighted)
        } header: {
            Text("Reports")
        } footer: {
            Text("Each report holds the run's record, Wine's exception trail, the game's "
                + "own crash logs and Steam's, with paths, account names and Steam ids "
                + "taken out.")
        }
    }

    private var reportsDetail: String {
        let count = CrashCollector.reports().count
        guard count > 0 else { return "Every game you run gets one. Nothing collected yet." }
        let size = ByteCountFormatter.string(
            fromByteCount: Int64(reportBytes), countStyle: .file,
        )
        return "\(count) \(count == 1 ? "report" : "reports"), \(size)."
    }

    // MARK: - The caps

    private var capsSection: some View {
        Section {
            ForEach(Self.caps, id: \.what) { cap in
                LabeledContent(cap.what) {
                    Text(cap.limit).foregroundStyle(.secondary)
                }
            }
            .highlightable(.diagnosticsCaps, highlighted: highlighted)
        } header: {
            Text("What it may take")
        } footer: {
            Text("Every one of these is enforced as it is written: the oldest goes first, "
                + "and nothing here can grow without a bound.")
        }
    }

    /// What each store is allowed, in the plan's own terms.
    private static let caps: [(what: String, limit: String)] = [
        ("App log", "10 MB"),
        ("Wine log", "20 MB"),
        ("Run records", "12 months"),
        ("Collected reports", "200 MB"),
        ("Compressed reports", "500 MB"),
    ]

    // MARK: - Actions

    private func refresh() {
        level = DiagnosticLevel.current
        reportBytes = CrashCollector.reports().reduce(0) { $0 + $1.bytes }
    }

    private func reveal() {
        let root = CrashCollector.root
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([root])
    }
}

/// Debug mode beside the level it overrides: the playtest switch that turns
/// everything on for one session.
private struct DebugModeRow: View {
    private static let help = SettingHelp(
        title: "Debug mode",
        summary: "One switch for reproducing a bug: it sets everything a report needs, "
            + "and takes it all off again when it ends.",
        entries: [
            .init(
                name: "What it records",
                text: "Every library a game loads, the renderer's own errors in a file of "
                    + "their own, and how each frame reached the screen.",
            ),
            .init(
                name: "How it differs from the level",
                text: "The level is kept and costs little. Debug mode costs speed and disk, "
                    + "so it lives only as long as this session.",
            ),
        ],
        footnote: "Also in the menu bar popover, under the … button.",
    )

    var body: some View {
        HelpedRow(caption: "Records everything for one session. Turn it on before reproducing a bug.", help: Self.help) {
            Toggle("Debug mode", isOn: Binding(
                get: { DebugModeSwitch.shared.isOn },
                set: { DebugModeSwitch.shared.set($0) },
            ))
            .toggleStyle(.switch)
        }
    }
}

/// The zip for a bug report.
private struct SaveDiagnosticsRow: View {
    @State private var error: String?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Diagnostics archive")
                Text(error ?? "Logs, system details and recent crashes in a ZIP on your Desktop, "
                    + "with your name, paths and Steam ids taken out.")
                    .font(.caption)
                    .foregroundStyle(error == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            SaveDiagnosticsButton(title: "Save…", error: $error)
        }
    }
}
