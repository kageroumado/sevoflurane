import SwiftUI

/// Settings: General (login item), Graphics (the bottle's renderer knobs),
/// Repair (the idempotent provisioner, re-run on demand), About. The wizard
/// covers first run; this is everything after it.
///
/// A searchable sidebar rather than a row of tabs, because the knobs that
/// bring someone here are the ones they know by name — "msync", "renderer",
/// "open at login" — and not by which pane happens to hold them. Searching
/// lists the matching settings themselves; picking one opens its pane and
/// flashes the row.
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
    @State private var highlighted: String?

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
                    id: "general.openAtLogin",
                    title: "Open at login",
                    keywords: ["login", "startup", "start", "launch", "menu bar", "automatic"],
                ),
                SearchableSetting(
                    id: "general.steamSettings",
                    title: "Steam's own settings",
                    keywords: ["steam", "settings", "downloads", "controller", "interface"],
                ),
                SearchableSetting(
                    id: "general.cli",
                    title: "Command-line tool",
                    keywords: ["cli", "sevo", "command", "terminal", "path"],
                ),
                SearchableSetting(
                    id: "general.agents",
                    title: "AI assistants (MCP)",
                    keywords: [
                        "mcp", "agent", "assistant", "ai", "claude", "codex",
                        "chatgpt", "hermes", "automation",
                    ],
                ),
                SearchableSetting(
                    id: "general.uninstall",
                    title: "Uninstall Sevoflurane",
                    keywords: ["uninstall", "remove", "delete", "reset", "clean"],
                ),
            ]
        case .graphics:
            [
                SearchableSetting(
                    id: "graphics.renderer",
                    title: "Game renderer",
                    keywords: [
                        "renderer", "graphics", "direct3d", "d3d", "d3dmetal",
                        "dxmt", "dxvk", "wined3d", "gpu", "metal",
                    ],
                ),
                SearchableSetting(
                    id: "graphics.gpu",
                    title: "Report the GPU as",
                    keywords: [
                        "gpu", "graphics card", "nvidia", "geforce", "amd", "radeon",
                        "vendor", "driver", "outdated", "unsupported",
                    ],
                ),
                SearchableSetting(
                    id: "graphics.shaders",
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
                    id: "engine.selection",
                    title: "Wine engine & bottle",
                    keywords: [
                        "engine", "wine", "crossover", "preview", "bottle",
                        "prefix", "built-in", "builtin", "switch",
                    ],
                ),
                SearchableSetting(
                    id: "engine.msync",
                    title: "Enhanced synchronization (msync)",
                    keywords: [
                        "msync", "sync", "synchronization", "performance",
                        "deadlock", "hang", "esync",
                    ],
                ),
                SearchableSetting(
                    id: "engine.windows",
                    title: "Game windows",
                    keywords: ["window", "resizable", "fullscreen", "fixed", "scale"],
                ),
                SearchableSetting(
                    id: "engine.upscaler",
                    title: "Upscaler",
                    keywords: [
                        "upscaler", "upscale", "lanczos", "metalfx", "shader",
                        "anime4k", "cunny", "resolution", "sharp",
                    ],
                ),
                SearchableSetting(
                    id: "engine.filter",
                    title: "Final filter",
                    keywords: ["filter", "nearest", "bilinear", "lanczos", "resample", "pixel"],
                ),
                SearchableSetting(
                    id: "engine.dependencies",
                    title: "Missing game dependencies",
                    keywords: [
                        "dependency", "vcruntime", "msvcp140", "vcredist", "vc++",
                        "redist", "fonts", "corefonts", "directx", "d3dx9",
                        "xaudio", "xact", "japanese", "chinese", "korean",
                        "winetricks", "missing", "dll",
                    ],
                ),
                SearchableSetting(
                    id: "engine.winecfg",
                    title: "Wine configuration",
                    keywords: ["wine", "winecfg", "windows version", "configuration"],
                ),
                SearchableSetting(
                    id: "engine.overrides",
                    title: "DLL overrides",
                    keywords: ["dll", "override", "native", "builtin", "library"],
                ),
                SearchableSetting(
                    id: "engine.repair",
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
                    id: "games.settings",
                    title: "Settings for one game",
                    keywords: [
                        "game", "per-game", "app", "inherit", "window", "upscaler",
                        "filter", "mouse", "override",
                    ],
                ),
            ]
        case .storage:
            [
                SearchableSetting(
                    id: "storage.games",
                    title: "What is using space",
                    keywords: [
                        "storage", "space", "disk", "size", "games", "cache",
                        "bottle", "engine", "clean", "free", "uninstall game",
                    ],
                ),
                SearchableSetting(
                    id: "storage.sharing",
                    title: "Share games between bottles",
                    keywords: [
                        "share", "link", "symlink", "bottle", "games",
                        "redownload", "copy",
                    ],
                ),
            ]
        case .about:
            [SearchableSetting(
                id: "about.version",
                title: "Version",
                keywords: ["about", "version", "build", "github", "source", "kageroumado"],
            )]
        }
    }
}

struct SearchableSetting: Identifiable, Equatable {
    let id: String
    let title: String
    let keywords: [String]

    func matches(_ search: String) -> Bool {
        let needle = search.lowercased()
        return title.lowercased().contains(needle) || keywords.contains { $0.contains(needle) }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    @Binding var category: SettingsCategory
    @Binding var searchText: String
    @Binding var highlighted: String?

    private var results: [(category: SettingsCategory, items: [SearchableSetting])] {
        SettingsCategory.allCases.compactMap { category in
            let items = category.searchableItems.filter { $0.matches(searchText) }
            return items.isEmpty ? nil : (category, items)
        }
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
                ForEach(results, id: \.category.id) { result in
                    Section {
                        ForEach(result.items) { item in
                            Button { reveal(item, in: result.category) } label: {
                                HStack {
                                    Text(item.title).foregroundStyle(.primary)
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Label(result.category.title, systemImage: result.category.icon)
                    }
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
    let highlighted: String?
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
    let id: String
    let highlighted: String?

    func body(content: Content) -> some View {
        content
            .padding(.vertical, 4)
            .padding(.horizontal, 12)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(highlighted == id ? Color.accentColor.opacity(0.2) : .clear)
                    .animation(.easeInOut(duration: 0.3), value: highlighted),
            )
    }
}

extension View {
    func highlightable(id: String, highlighted: String?) -> some View {
        modifier(HighlightModifier(id: id, highlighted: highlighted))
    }
}
