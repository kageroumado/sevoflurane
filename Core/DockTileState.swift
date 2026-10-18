import Foundation

/// What a game's Dock tile shows while the game is not running, written for
/// the tile plug-in (``GameLaunchers/dockTilePlugIn``) to read: the
/// renderers its Play with menu offers, a word for a badge, a download's
/// progress. One file beside every bundle for the game's own state, one
/// beside the bundles for the renderers, which are the machine's.
nonisolated enum DockTileState {
    struct Renderer: Codable {
        let id: String
        let label: String
    }

    struct State: Codable, Equatable {
        var badge: String?
        var progress: Double?
    }

    /// Writes the renderers every tile offers.
    static func writeRenderers(_ renderers: [(id: String, label: String)]) {
        let file = GameLaunchers.renderersFile
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        write(renderers.map { Renderer(id: $0.id, label: $0.label) }, to: file)
    }

    /// Writes one game's badge and progress; `nil` for both removes the file.
    static func write(_ state: State, appID: Int) {
        let file = GameLaunchers.tileStateFile(appID: appID)
        if state == State() {
            try? FileManager.default.removeItem(at: file)
            return
        }
        guard FileManager.default.fileExists(atPath: file.deletingLastPathComponent().path) else { return }
        write(state, to: file)
    }

    private static func write(_ value: some Encodable, to file: URL) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        if (try? Data(contentsOf: file)) == data { return }
        try? data.write(to: file, options: .atomic)
    }
}
