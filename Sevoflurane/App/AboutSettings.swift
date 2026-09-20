import SwiftUI

// MARK: - About

struct AboutSettings: View {
    let highlighted: SettingsAnchor?
    @State private var savingDiagnostics = false
    @State private var diagnosticsError: String?

    /// The bundled CLI writes the zip (`sevo diag`), so the app and the
    /// terminal produce the same report; Finder then shows it.
    private func saveDiagnostics() {
        savingDiagnostics = true
        diagnosticsError = nil
        Task(name: "Save diagnostics") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
            let result = await Subprocess.run(
                helper.path, ["diag", "--steam-logs"], capture: .combined, timeout: .seconds(90),
            )
            savingDiagnostics = false
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            guard result.status == 0, path.hasSuffix(".zip") else {
                diagnosticsError = "Could not write the report: \(result.output.suffix(200))"
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .bold))
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(
                    "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://kagerou.glass")!,
                )
                Link(
                    "GitHub \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://github.com/kageroumado/sevoflurane")!,
                )
            }
            .font(.system(size: 12))
            HStack(spacing: 10) {
                Button("Acknowledgments") {
                    NSApp.sendAction(#selector(AppDelegate.showAcknowledgements(_:)), to: nil, from: nil)
                }
                Button("License") {
                    NSApp.sendAction(#selector(AppDelegate.showLicense(_:)), to: nil, from: nil)
                }
                Button(savingDiagnostics ? "Saving…" : "Save Diagnostics…") { saveDiagnostics() }
                    .disabled(savingDiagnostics)
                    .highlightable(.aboutDiagnostics, highlighted: highlighted)
            }
            .controlSize(.small)
            .padding(.top, 6)
            Text("Saves logs, system details, and recent crashes to a ZIP on your Desktop. Read it before sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            if let diagnosticsError {
                Text(diagnosticsError).font(.caption).foregroundStyle(.red)
            }
        }
        .highlightable(.aboutVersion, highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
