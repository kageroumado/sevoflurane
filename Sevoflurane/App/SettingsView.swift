import SwiftUI

/// What Settings can ask of the running Steam client — injected by the
/// window so the panes stay host-free, and absent in the gallery, whose
/// tiles must never uninstall anything.
@MainActor
struct SteamActions {
    /// Brings Steam up and opens its own settings window.
    var openSteamSettings: () -> Void
    /// The client's uninstall flow for one app; its confirmation dialog
    /// arrives as a native window.
    var uninstall: (_ appID: Int) -> Void
    var restartClient: () -> Void
}

/// Settings: General, Graphics, Engine, Games, Storage, About. The wizard
/// covers first run; this is everything after it.
///
/// A searchable sidebar rather than a row of tabs, because the knobs that
/// bring someone here are the ones they know by name — "msync", "renderer",
/// "open at login" — and not by which pane happens to hold them. Searching
/// lists the matching settings themselves; picking one opens its pane and
/// flashes the row.
struct SettingsView: View {
    let provisioner: Provisioner
    let graphics: GraphicsStore
    let storage: StorageStore
    let engine: EngineStore
    let shaders: ShaderStore
    var compatibility = CompatibilityStore()
    var steam: SteamActions?
    /// Stood down by the General pane's uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    @State private var category: SettingsCategory = .general
    @State private var searchText = ""
    @State private var highlighted: SettingsAnchor?

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                category: $category,
                searchText: $searchText,
                highlighted: $highlighted,
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPane(
                category: category,
                provisioner: provisioner,
                graphics: graphics,
                storage: storage,
                engine: engine,
                shaders: shaders,
                compatibility: compatibility,
                steam: steam,
                highlighted: highlighted,
                supervisor: supervisor,
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: category, initial: true) { _, category in
            EventLog.shared.log(.window, "settings: showing \(category.title)")
        }
        .onChange(of: searchText.isEmpty) { _, isEmpty in
            EventLog.shared.log(
                .window,
                isEmpty ? "settings: sidebar search cleared" : "settings: sidebar search active",
            )
        }
    }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case graphics
    case engine
    case games
    case storage
    case about

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .general: "General"
        case .graphics: "Graphics"
        case .engine: "Engine"
        case .games: "Games"
        case .storage: "Storage"
        case .about: "About"
        }
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .graphics: "cpu.fill"
        case .engine: "wrench.and.screwdriver.fill"
        case .games: "gamecontroller.fill"
        case .storage: "internaldrive.fill"
        case .about: "info.circle.fill"
        }
    }

    /// What search matches on — one entry per row a pane can flash.
    var searchableItems: [SearchableSetting] {
        switch self {
        case .general:
            [
                SearchableSetting(
                    id: .generalOpenAtLogin,
                    title: "Open at login",
                    keywords: ["login", "startup", "start", "launch", "menu bar", "automatic"],
                ),
                SearchableSetting(
                    id: .generalSteamSettings,
                    title: "Steam's own settings",
                    keywords: ["steam", "settings", "downloads", "controller", "interface"],
                ),
                SearchableSetting(
                    id: .generalCli,
                    title: "Command-line tool",
                    keywords: ["cli", "sevo", "command", "terminal", "path"],
                ),
                SearchableSetting(
                    id: .generalAgents,
                    title: "AI assistants (MCP)",
                    keywords: [
                        "mcp", "agent", "assistant", "ai", "claude", "codex",
                        "chatgpt", "hermes", "automation",
                    ],
                ),
                SearchableSetting(
                    id: .generalUninstall,
                    title: "Uninstall Sevoflurane",
                    keywords: ["uninstall", "remove", "delete", "reset", "clean"],
                ),
            ]
        case .graphics:
            [
                SearchableSetting(
                    id: .graphicsRenderer,
                    title: "Game renderer",
                    keywords: [
                        "renderer", "graphics", "direct3d", "d3d", "d3dmetal",
                        "dxmt", "dxvk", "wined3d", "gpu", "metal",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsGpu,
                    title: "Report the GPU as",
                    keywords: [
                        "gpu", "graphics card", "nvidia", "geforce", "amd", "radeon",
                        "vendor", "driver", "outdated", "unsupported",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsShaders,
                    title: "Shader packages",
                    keywords: [
                        "shader", "package", "upscaler", "anime4k", "cunny",
                        "download", "license",
                    ],
                ),
            ]
        case .engine:
            [
                SearchableSetting(
                    id: .engineSelection,
                    title: "Wine engine & bottle",
                    keywords: [
                        "engine", "wine", "crossover", "preview", "bottle",
                        "prefix", "built-in", "builtin", "dormison", "switch",
                    ],
                ),
                SearchableSetting(
                    id: .engineMsync,
                    title: "Enhanced synchronization (msync)",
                    keywords: [
                        "msync", "sync", "synchronization", "performance",
                        "deadlock", "hang", "esync",
                    ],
                ),
                SearchableSetting(
                    id: .engineWindows,
                    title: "Make game windows resizable",
                    keywords: [
                        "window", "resizable", "resize", "move", "fullscreen",
                        "full screen", "fixed", "scale",
                    ],
                ),
                SearchableSetting(
                    id: .engineUpscaler,
                    title: "Upscaler",
                    keywords: [
                        "upscaler", "upscale", "lanczos", "metalfx", "shader",
                        "anime4k", "cunny", "resolution", "sharp",
                    ],
                ),
                SearchableSetting(
                    id: .engineFilter,
                    title: "Final filter",
                    keywords: ["filter", "nearest", "bilinear", "lanczos", "resample", "pixel"],
                ),
                SearchableSetting(
                    id: .engineDependencies,
                    title: "Missing game dependencies",
                    keywords: [
                        "dependency", "vcruntime", "msvcp140", "vcredist", "vc++",
                        "redist", "fonts", "corefonts", "directx", "d3dx9",
                        "xaudio", "xact", "japanese", "chinese", "korean",
                        "winetricks", "missing", "dll",
                    ],
                ),
                SearchableSetting(
                    id: .engineMouse,
                    title: "Mouse",
                    keywords: [
                        "mouse", "pointer", "cursor", "acceleration", "linear",
                        "sensitivity", "aim", "mouse-look", "fps",
                    ],
                ),
                SearchableSetting(
                    id: .engineWinecfg,
                    title: "Wine configuration",
                    keywords: ["wine", "winecfg", "windows version", "configuration"],
                ),
                SearchableSetting(
                    id: .engineWineDiagnostics,
                    title: "Log every library a game loads",
                    keywords: [
                        "wine", "diagnostics", "log", "logging", "debug",
                        "winedebug", "trace", "error", "crash", "library", "dll", "loaddll",
                    ],
                ),
                SearchableSetting(
                    id: .engineOverrides,
                    title: "DLL overrides",
                    keywords: ["dll", "override", "native", "builtin", "library"],
                ),
                SearchableSetting(
                    id: .engineRepair,
                    title: "Repair the installation",
                    keywords: [
                        "repair", "reinstall", "fix", "setup", "provision",
                        "broken",
                    ],
                ),
            ]
        case .games:
            [
                SearchableSetting(
                    id: .gamesSettings,
                    title: "Settings for one game",
                    keywords: [
                        "game", "per-game", "app", "inherit", "window", "upscaler",
                        "filter", "mouse", "override",
                    ],
                ),
                SearchableSetting(
                    id: .gamesUpscaler,
                    title: "Upscaler for one game",
                    keywords: [
                        "upscaler", "upscale", "lanczos", "metalfx", "shader",
                        "anime4k", "cunny", "resolution", "sharp", "per-game",
                    ],
                ),
            ]
        case .storage:
            [
                SearchableSetting(
                    id: .storageGames,
                    title: "What is using space",
                    keywords: [
                        "storage", "space", "disk", "size", "games", "cache",
                        "bottle", "engine", "clean", "free", "uninstall game",
                    ],
                ),
                SearchableSetting(
                    id: .storageSharing,
                    title: "Share games between bottles",
                    keywords: [
                        "share", "link", "symlink", "bottle", "games",
                        "redownload", "copy",
                    ],
                ),
            ]
        case .about:
            [
                SearchableSetting(
                    id: .aboutVersion,
                    title: "Version",
                    keywords: ["about", "version", "build", "github", "source", "kageroumado"],
                ),
                SearchableSetting(
                    id: .aboutDiagnostics,
                    title: "Save Diagnostics…",
                    keywords: [
                        "diagnostics", "diagnostic", "report", "logs", "log",
                        "zip", "bug", "crash", "support", "send",
                    ],
                ),
            ]
        }
    }
}

struct SearchableSetting: Identifiable, Equatable {
    let id: SettingsAnchor
    let title: String
    let keywords: [String]

    func matches(_ search: String) -> Bool {
        let needle = search.lowercased()
        return title.lowercased().contains(needle) || keywords.contains { $0.contains(needle) }
    }
}

/// Every row search can send someone to. A pane marks its row with the anchor
/// (``SwiftUI/View/highlightable(_:highlighted:)``) and
/// ``SettingsCategory/searchableItems`` names it; the two sets are the same
/// one, and `SettingsSearchTests` fails if they drift. A row with no anchor is
/// a row search cannot reach, and an anchor with no searchable item is a flash
/// nothing can ask for.
enum SettingsAnchor: String, CaseIterable {
    case generalOpenAtLogin = "general.openAtLogin"
    case generalSteamSettings = "general.steamSettings"
    case generalCli = "general.cli"
    case generalAgents = "general.agents"
    case generalUninstall = "general.uninstall"
    case graphicsRenderer = "graphics.renderer"
    case graphicsGpu = "graphics.gpu"
    case graphicsShaders = "graphics.shaders"
    case engineSelection = "engine.selection"
    case engineMsync = "engine.msync"
    case engineWindows = "engine.windows"
    case engineUpscaler = "engine.upscaler"
    case engineFilter = "engine.filter"
    case engineMouse = "engine.mouse"
    case engineDependencies = "engine.dependencies"
    case engineOverrides = "engine.overrides"
    case engineWinecfg = "engine.winecfg"
    case engineWineDiagnostics = "engine.wineDiagnostics"
    case engineRepair = "engine.repair"
    case gamesSettings = "games.settings"
    case gamesUpscaler = "games.upscaler"
    case storageGames = "storage.games"
    case storageSharing = "storage.sharing"
    case aboutDiagnostics = "about.diagnostics"
    case aboutVersion = "about.version"
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var category: SettingsCategory
    @Binding var searchText: String
    @Binding var highlighted: SettingsAnchor?

    /// One row per matching setting, each carrying the pane it lives in.
    ///
    /// Flat by design: the sidebar is a `List`, and a `Section` header row
    /// beside content rows gives AppKit's table two kinds of row view to
    /// constrain against each other when the results change under a live
    /// selection — the layout exception that took the app down. Grouping by
    /// pane belongs in the row, not in the list's structure.
    private var matches: [Match] {
        SettingsCategory.allCases.flatMap { category in
            category.searchableItems
                .filter { $0.matches(searchText) }
                .map { Match(category: category, item: $0) }
        }
    }

    private struct Match: Identifiable {
        let category: SettingsCategory
        let item: SearchableSetting

        var id: SettingsAnchor { item.id }
    }

    var body: some View {
        List(selection: $category) {
            if searchText.isEmpty {
                ForEach(SettingsCategory.allCases) { category in
                    Label {
                        Text(category.title)
                    } icon: {
                        Image(systemName: category.icon)
                            .foregroundStyle(Color.accentColor)
                    }
                    .tag(category)
                }
            } else {
                ForEach(matches) { match in
                    Button { reveal(match.item, in: match.category) } label: {
                        Label {
                            HStack {
                                Text(match.item.title).foregroundStyle(.primary)
                                Spacer(minLength: 8)
                                Text(match.category.title).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: match.category.icon)
                                .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .searchable(text: $searchText, placement: .sidebar, prompt: "Search Settings")
        .navigationTitle("Settings")
        .frame(minWidth: 190)
    }

    /// Opens the setting's pane and flashes its row, long enough to find with
    /// the eye and short enough not to stay behind as decoration.
    private func reveal(_ item: SearchableSetting, in category: SettingsCategory) {
        self.category = category
        highlighted = item.id
        Task(name: "Clear settings highlight") {
            try? await Task.sleep(for: .seconds(1.8))
            highlighted = nil
        }
    }
}

// MARK: - Panes

private struct SettingsPane: View {
    let category: SettingsCategory
    let provisioner: Provisioner
    let graphics: GraphicsStore
    let storage: StorageStore
    let engine: EngineStore
    let shaders: ShaderStore
    let compatibility: CompatibilityStore
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    var supervisor: ClientSupervisor?

    var body: some View {
        Group {
            switch category {
            case .general:
                GeneralSettings(
                    provisioner: provisioner, store: storage, steam: steam,
                    highlighted: highlighted, supervisor: supervisor,
                )
            case .graphics:
                GraphicsSettings(store: graphics, shaders: shaders, steam: steam, highlighted: highlighted)
            case .engine:
                EngineSettings(
                    store: engine, graphics: graphics, shaders: shaders, compatibility: compatibility,
                    provisioner: provisioner, highlighted: highlighted,
                )
            case .games:
                GamesSettings(shaders: shaders, highlighted: highlighted)
            case .storage:
                StorageSettings(store: storage, steam: steam, highlighted: highlighted)
            case .about: AboutSettings(highlighted: highlighted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(category.title)
    }
}

/// Flashes a row the search sent the user to.
private struct HighlightModifier: ViewModifier {
    let anchor: SettingsAnchor?
    let highlighted: SettingsAnchor?

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(isLit ? Color.accentColor.opacity(0.2) : .clear)
                    .animation(.easeInOut(duration: 0.3), value: highlighted),
            )
    }

    private var isLit: Bool {
        guard let anchor else { return false }
        return highlighted == anchor
    }
}

extension View {
    /// Marks this row as the one search flashes for `anchor`. A `nil` anchor
    /// keeps the row's padding and gives it nothing to light up for — the
    /// shape of a list whose other rows are reachable and this one is not.
    func highlightable(_ anchor: SettingsAnchor?, highlighted: SettingsAnchor?) -> some View {
        modifier(HighlightModifier(anchor: anchor, highlighted: highlighted))
    }
}
