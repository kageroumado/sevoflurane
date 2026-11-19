import AppKit
import Foundation

/// The diagnostics zip, written by the bundled `sevo diag` so a button's zip
/// and a hand-run one are the same report.
enum DiagnosticsArchive {
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

