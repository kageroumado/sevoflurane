import AppKit

/// A game's Dock tile while the game is not running.
///
/// The Dock loads this out of the game's own bundle (`NSDockTilePlugIn` in
/// its Info.plist) once the tile is kept and the game has quit, in a process
/// of the Dock's own. From there the tile gets a menu — Play, Play with a
/// renderer, Game Settings — and a badge or a progress bar when the app has
/// something to say about the game. The game's id is in the bundle's
/// identifier; everything else is read from `tile.json` beside the bundle,
/// which Sevoflurane writes, and every choice goes back to Sevoflurane as a
/// `sevoflurane://` URL, since the Dock's process shares nothing else with it.
@objc(DockTilePlugIn)
final class DockTilePlugIn: NSObject, NSDockTilePlugIn {
    private var dockTile: NSDockTile?
    private var state = TileState()
    private var watcher: DispatchSourceFileSystemObject?

    /// The game's bundle: this plug-in lives in its `Contents/PlugIns`.
    private let gameBundle: URL = Bundle(for: DockTilePlugIn.self).bundleURL
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// The game's id, the tail of the bundle identifier `….game.<id>`.
    private lazy var gameID: Int? = {
        let identifier = Bundle(url: gameBundle)?.bundleIdentifier ?? ""
        guard let dot = identifier.lastIndex(of: ".") else { return nil }
        return Int(identifier[identifier.index(after: dot)...])
    }()

    private var stateFile: URL {
        gameBundle.deletingLastPathComponent().appendingPathComponent("tile.json")
    }

    /// The renderers the machine offers, beside every game's folder.
    private var renderersFile: URL {
        gameBundle.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("renderers.json")
    }

    func setDockTile(_ dockTile: NSDockTile?) {
        self.dockTile = dockTile
        watcher?.cancel()
        watcher = nil
        guard dockTile != nil else { return }
        reload()
        watch()
    }

    func dockMenu() -> NSMenu? {
        guard let gameID else { return nil }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(item(String(localized: "Play"), route: "play/\(gameID)"))
        let renderers = TileRenderer.read(renderersFile)
        if !renderers.isEmpty {
            let submenu = NSMenu()
            submenu.autoenablesItems = false
            for renderer in renderers {
                submenu.addItem(item(renderer.label, route: "play/\(gameID)?renderer=\(renderer.id)"))
            }
            let parent = NSMenuItem(title: String(localized: "Play with"), action: nil, keyEquivalent: "")
            parent.submenu = submenu
            menu.addItem(parent)
        }
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Game Settings…"), route: "settings/\(gameID)"))
        return menu
    }

    private func item(_ title: String, route: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(open(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = route
        return item
    }

    @objc
    private func open(_ sender: NSMenuItem) {
        guard let route = sender.representedObject as? String,
              let url = URL(string: "sevoflurane://\(route)") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - What the app says about the game

    private func reload() {
        state = TileState(contentsOf: stateFile)
        guard let dockTile else { return }
        dockTile.badgeLabel = state.badge
        dockTile.contentView = state.progress.map { ProgressTileView(progress: $0, icon: icon) }
        dockTile.display()
    }

    private var icon: NSImage {
        NSWorkspace.shared.icon(forFile: gameBundle.path)
    }

    /// The state file is rewritten whole, so the directory is what changes.
    private func watch() {
        let directory = stateFile.deletingLastPathComponent()
        let descriptor = Darwin.open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: .main,
        )
        source.setEventHandler { [weak self] in self?.reload() }
        source.setCancelHandler { close(descriptor) }
        source.resume()
        watcher = source
    }
}

/// `tile.json` beside the game's bundle, as Sevoflurane writes it. Either
/// key may be absent: a file is only there while one of them is set.
struct TileState: Decodable {
    /// A word on the tile: "update", say.
    var badge: String?
    /// A download or patch in flight, 0…1.
    var progress: Double?

    init() {}

    init(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TileState.self, from: data) else { return }
        self = decoded
    }
}

/// One renderer of `renderers.json`, beside every game's folder, for the
/// Play with submenu.
struct TileRenderer: Decodable {
    let id: String
    let label: String

    static func read(_ url: URL) -> [TileRenderer] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([TileRenderer].self, from: data)) ?? []
    }
}

/// The game's icon with a progress bar along its bottom, the way a download
/// shows on a browser's tile.
final class ProgressTileView: NSView {
    private let progress: Double
    private let icon: NSImage

    init(progress: Double, icon: NSImage) {
        self.progress = progress
        self.icon = icon
        super.init(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) { nil }

    override func draw(_: NSRect) {
        icon.draw(in: bounds)
        let inset = bounds.width * 0.12
        let track = NSRect(x: inset, y: bounds.height * 0.1, width: bounds.width - 2 * inset, height: bounds.height * 0.09)
        let radius = track.height / 2
        NSColor(white: 0, alpha: 0.55).setFill()
        NSBezierPath(roundedRect: track, xRadius: radius, yRadius: radius).fill()
        var fill = track.insetBy(dx: 2, dy: 2)
        fill.size.width *= min(max(progress, 0), 1)
        NSColor.white.setFill()
        NSBezierPath(roundedRect: fill, xRadius: fill.height / 2, yRadius: fill.height / 2).fill()
    }
}
