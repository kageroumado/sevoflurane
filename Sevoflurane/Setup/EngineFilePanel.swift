import AppKit
import UniformTypeIdentifiers

/// The open panel for an engine on disk, shared by the wizard and Settings ›
/// Engine so both ask for the same thing in the same words.
@MainActor
enum EngineFilePanel {
    /// Runs the panel and returns the chosen tarball or engine folder, or
    /// `nil` when it was dismissed.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.message = "Choose the dormison-r<N>.tar.xz you downloaded, or an engine "
            + "folder you built. Sevoflurane checks the .sig beside a tarball "
            + "against the engine key."
        panel.prompt = "Install"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "xz"), UTType(filenameExtension: "txz"), .archive,
        ].compactMap(\.self)
        // A directory is a choice, not a place to descend into: the tree
        // `package-engine.sh` assembles is what the tarball holds.
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
