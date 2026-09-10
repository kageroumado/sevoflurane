import AppKit
import UniformTypeIdentifiers

/// The open panel for an engine tarball, shared by the wizard and Settings ›
/// Engine so both ask for the same file in the same words.
@MainActor
enum EngineFilePanel {
    /// Runs the panel and returns the chosen tarball, or `nil` when it was
    /// dismissed.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the dormison-r<N>.tar.xz you downloaded. Sevoflurane "
            + "checks the .sig beside it against the engine key."
        panel.prompt = "Install"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xz"), UTType(filenameExtension: "txz"), .archive,
        ].compactMap(\.self)
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
