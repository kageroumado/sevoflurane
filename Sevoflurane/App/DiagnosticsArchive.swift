import AppKit
import SwiftUI

/// The diagnostics zip, as Settings writes it.
///
/// The bundled CLI does the writing (`sevo diag`), so a zip saved from a
/// button and one from a hand-run `sevo diag` are the same report.
enum DiagnosticsArchive {
    /// The `sevo` helper inside this bundle.
    static var helper: URL {
        Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
    }

    private static let timeout = Duration.seconds(90)

    /// Writes the zip to the Desktop and shows it in Finder.
    ///
    /// - Returns: what went wrong, in a sentence, or `nil`.
    static func save() async -> String? {
        let result = await Subprocess.run(
            helper.path, ["diag", "--steam-logs"], capture: .combined, timeout: timeout,
        )
        let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
        guard result.status == 0, path.hasSuffix(".zip") else {
            return String(localized: "Could not write the report: \(result.output.suffix(200))")
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        return nil
    }
}

/// The button that saves the zip, with its own progress and its own error.
struct SaveDiagnosticsButton: View {
    let title: LocalizedStringKey
    @Binding var error: String?
    @State private var isSaving = false

    var body: some View {
        Button(isSaving ? "Saving…" : title) {
            isSaving = true
            error = nil
            Task(name: "Save diagnostics") {
                error = await DiagnosticsArchive.save()
                isSaving = false
            }
        }
        .disabled(isSaving)
    }
}
