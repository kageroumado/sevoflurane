import AppKit
import Propofol
import SwiftUI

/// Settings › Diagnostics: how much a run records, where it is kept, and the
/// disk limits. The level reaches games at their next launch through the
/// bottle's env files; level two takes itself off after one game.
struct DiagnosticsSettings: View {
    let store: DiagnosticsStore
    let highlighted: SettingsAnchor?
    /// Opens the report window; absent in the gallery.
    var showReports: (() -> Void)?

    var body: some View {
        Form {
            levelSection
            guideSection
            reportsSection
            capsSection
        }
        .formStyle(.grouped)
        .task { store.refresh() }
    }

    private var level: DiagnosticLevel {
        store.level
    }

    // MARK: - The level

    private var levelSection: some View {
        Section {
            HelpedRow(caption: level.caption, help: Self.levelHelp) {
                Picker("Record", selection: levelBinding) {
                    ForEach(DiagnosticLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
            }
            .highlightable(.diagnosticsLevel, highlighted: highlighted)
            ActionRow(title: "Wine channels") {
                Text(level.channels())
                    .font(.callout.monospaced())
            }
            DebugModeRow()
                .highlightable(.diagnosticsDebugMode, highlighted: highlighted)
        } header: {
            Text("Recording")
        } footer: {
            Text("A level reaches each game the next time it is launched. Debug mode reaches Steam when Steam restarts, and ends when Sevoflurane quits.")
        }
    }

    /// Each level in full, behind the Record row's (i).
    private static let levelHelp = SettingHelp(
        title: "How much a run records",
        summary: "Each level adds to the one before it and costs more speed and disk.",
        entries: DiagnosticLevel.allCases.map { .init(name: $0.title, text: $0.detail) },
    )

    private var levelBinding: Binding<DiagnosticLevel> {
        Binding(get: { store.level }, set: { store.setLevel($0) })
    }

    // MARK: - The guide

    /// How to make a run someone can act on, in order; `sevo diag --help` has
    /// the longer guide.
    private var guideSection: some View {
        Section {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                ForEach(Self.guide.enumerated(), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                        Text(verbatim: "\(index + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .highlightable(.diagnosticsGuide, highlighted: highlighted)
        } header: {
            Text("Making a useful report")
        } footer: {
            Text("In Terminal, sevo diag --help shows these steps. Use sevo perf compare to measure a setting's effect.")
        }
    }

    private static let guide: [LocalizedStringResource] = [
        "Set Record to Diagnostics before you launch the game.",
        "After the game loads, play for at least a minute in an area you can return to.",
        "To test a setting, change one value and play the same area twice with each.",
        "When the problem occurs, save a diagnostics archive below.",
        "Set Record back to Off when you are done.",
    ]

    // MARK: - Where it goes

    private var reportsSection: some View {
        Section {
            ActionRow(title: "Run reports", caption: reportsDetail) {
                Button("Show in Finder") { store.revealReports() }
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
            Text("Each report holds the run's record, Wine's exception trail, the game's own crash logs and Steam's, with paths, account names and Steam ids taken out.")
        }
    }

    private var reportsDetail: String {
        guard store.reportCount > 0 else {
            return String(localized: "Every game you run gets one. Nothing collected yet.")
        }
        let size = Int64(store.reportBytes).formatted(.byteCount(style: .file))
        return String(localized: "\(store.reportCount) reports, \(size).")
    }

    // MARK: - The caps

    private var capsSection: some View {
        Section {
            ForEach(Self.caps, id: \.what) { cap in
                SettingsRow {
                    LabeledContent(InterfaceCopy.localized(cap.what)) {
                        Text(InterfaceCopy.localized(cap.limit))
                    }
                }
            }
            .highlightable(.diagnosticsCaps, highlighted: highlighted)
        } header: {
            Text("Storage limits")
        } footer: {
            Text("Each limit is enforced as files are written; the oldest goes first.")
        }
    }

    private static let caps: [(what: String, limit: String)] = [
        ("App log", "10 MB"),
        ("Wine log", "20 MB"),
        ("Run records", "12 months"),
        ("Collected reports", "200 MB"),
        ("Compressed reports", "500 MB"),
    ]
}

/// Debug mode beside the level it overrides: everything on, for one session.
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
        HelpedRow(caption: InterfaceCopy.localized("Records everything for one session. Turn it on before reproducing a bug."), help: Self.help) {
            Toggle("Debug mode", isOn: Binding(
                get: { DebugModeSwitch.shared.isOn },
                set: { DebugModeSwitch.shared.set($0) },
            ))
            .toggleStyle(.switch)
            .accessibilityLabel("Debug mode")
        }
    }
}

private struct SaveDiagnosticsRow: View {
    @State private var error: String?

    var body: some View {
        ActionRow(
            title: "Diagnostics archive",
            caption: error ?? String(localized: "Logs, system details and recent crashes in a ZIP on your Desktop."),
            isWarning: error != nil,
            help: .diagnosticsArchive,
        ) {
            SaveDiagnosticsButton(title: "Save…", error: $error)
        }
    }
}
