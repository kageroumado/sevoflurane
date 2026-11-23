import AppKit
import SwiftUI

/// Settings › Diagnostics: how much a run records, the switches that log
/// more for one session, and where the reports are kept. The level reaches
/// games at their next launch through the bottle's env files; level two takes
/// itself off after one game.
struct DiagnosticsSettings: View {
    let store: DiagnosticsStore
    let highlighted: SettingsAnchor?
    /// Opens the report window; absent in the gallery.
    var showReports: (() -> Void)?

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            SettingsSection(title: "Record", reach: .nextLaunch) {
                SettingsPicker(
                    title: "Record", caption: store.level.caption, help: Self.levelHelp, selection: levelBinding,
                ) {
                    ForEach(DiagnosticLevel.allCases, id: \.self) { level in
                        Text(level.title).tag(level)
                    }
                }
                .highlightable(.diagnosticsLevel, highlighted: highlighted)
                SettingsValue(title: "Wine channels", value: store.level.channels(), isCode: true)
            }
            SettingsSection(
                title: "Debugging", footer: "Debug mode ends when Sevoflurane quits.", reach: .clientRestart,
            ) {
                DebugModeRow()
                    .highlightable(.diagnosticsDebugMode, highlighted: highlighted)
                WineLogToggle()
                    .highlightable(.diagnosticsWineLog, highlighted: highlighted)
            }
            SettingsSection(
                title: "Reports",
                footer: "Kept to 200 MB of reports (500 MB compressed), 12 months of run records, a 10 MB app log, and a 20 MB Wine log. The oldest goes first.",
            ) {
                SettingsAction(title: "Run reports", caption: reportsDetail, help: .runReports) {
                    Button("Show in Finder") { store.revealReports() }
                    if let showReports {
                        Button("Open Reports") { showReports() }
                    }
                }
                .highlightable(.diagnosticsReports, highlighted: highlighted)
                SaveDiagnosticsRow()
                    .highlightable(.diagnosticsSave, highlighted: highlighted)
            }
        }
        .task { store.refresh() }
    }

    /// Each level in full, behind the Record row's (i).
    private static let levelHelp = SettingHelp(
        title: "Record",
        summary: "Each level adds to the one before it and costs more speed and disk.",
        entries: DiagnosticLevel.allCases.map { .init(name: $0.title, text: $0.detail) },
    )

    private var levelBinding: Binding<DiagnosticLevel> {
        Binding(get: { store.level }, set: { store.setLevel($0) })
    }

    private var reportsDetail: String {
        guard store.reportCount > 0 else {
            return String(localized: "Every game you run gets one. Nothing collected yet.")
        }
        let size = Int64(store.reportBytes).formatted(.byteCount(style: .file))
        return String(localized: "\(store.reportCount) reports, \(size).")
    }
}

/// Debug mode beside the level it overrides: everything on, for one session.
private struct DebugModeRow: View {
    var body: some View {
        SettingsToggle(
            title: "Debug mode",
            caption: String(localized: "Records everything for one session. Turn it on before reproducing a bug."),
            help: .debugMode,
            isOn: Binding(
                get: { DebugModeSwitch.shared.isOn },
                set: { DebugModeSwitch.shared.set($0) },
            ),
        )
    }
}

private struct WineLogToggle: View {
    @State private var wineDiagnostics = WineLog.isDiagnosing

    var body: some View {
        SettingsToggle(
            title: "Log every library a game loads",
            caption: String(localized: "The Wine log grows quickly while this is on."),
            help: .wineLog,
            isOn: $wineDiagnostics,
        )
        .onChange(of: wineDiagnostics) { _, enabled in
            WineLog.setDiagnosing(enabled)
        }
    }
}

private struct SaveDiagnosticsRow: View {
    @State private var error: String?

    var body: some View {
        SettingsAction(
            title: "Archive on your Desktop",
            caption: String(localized: "Logs, system details, and recent crashes in one ZIP."),
            state: .failure(ifPresent: error),
            help: .diagnosticsArchive,
        ) {
            SaveDiagnosticsButton(error: $error)
        }
    }
}
