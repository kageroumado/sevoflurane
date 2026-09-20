import AppKit

/// Who macOS hands a `steam://` link to: a store page's Install button, a
/// friend's join link, a shortcut. Sevoflurane declares the scheme, and so does
/// Valve's own Steam for Mac; with both installed macOS keeps whichever it saw
/// first until someone chooses.
@MainActor
enum SteamLinks {
    private static let probe = URL(string: "steam://open/main")

    /// The app macOS opens a `steam://` link with today.
    static var handler: URL? {
        probe.flatMap { NSWorkspace.shared.urlForApplication(toOpen: $0) }
    }

    /// Whether the links come here.
    static var comeHere: Bool {
        handler?.standardizedFileURL == Bundle.main.bundleURL.standardizedFileURL
    }

    /// The other app's name, for the sentence that names it.
    static var handlerName: String? {
        handler.map { FileManager.default.displayName(atPath: $0.path) }
    }

    /// Asks macOS to send the links here. macOS may confirm with the person first.
    static func claim() async -> Bool {
        do {
            try await NSWorkspace.shared.setDefaultApplication(
                at: Bundle.main.bundleURL, toOpenURLsWithScheme: "steam",
            )
            return comeHere
        } catch {
            return false
        }
    }
}
