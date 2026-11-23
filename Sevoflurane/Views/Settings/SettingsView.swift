import Propofol
import SwiftUI

/// What Settings can ask of the running Steam client; absent in the gallery.
@MainActor
struct SteamActions {
    /// Brings Steam up and opens its own settings window.
    var openSteamSettings: () -> Void
    /// The client's uninstall flow for one app.
    var uninstall: (_ appID: Int) -> Void
    var restartClient: () -> Void
    /// Ends a stuck menu-bar tracking session, answering which root menus were open.
    var cancelStuckMenus: () -> [String]
    /// Applies the Mac compatibility strip switch to the open game page.
    var applyCompatibilityStrip: () -> Void
    /// Applies the Styles folder's stylesheet switches to open windows and pages.
    var applyUserStyles: () -> Void
    /// Reloads Steam's pages so they carry the Streamer Mode mask, or lose it.
    var applyStreamerMode: () -> Void
}

/// Settings, one pane per ``SettingsCategory``. The sidebar search lists
/// matching settings by name; picking one opens its pane and flashes the row.
struct SettingsView: View {
    let provisioner: Provisioner
    let graphics: GraphicsStore
    let storage: StorageStore
    let engine: EngineStore
    let shaders: ShaderStore
    let compatibility: CompatibilityStore
    let diagnostics: DiagnosticsStore
    var steam: SteamActions?
    /// Stood down by the General pane's uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    /// Opens the report window; absent in the gallery.
    var showReports: (() -> Void)?
    @Bindable var navigation = SettingsNavigation()

    var body: some View {
        NavigationSplitView {
            SettingsSidebar(
                category: $navigation.category,
                searchText: $navigation.searchText,
                highlighted: $navigation.highlighted,
            )
            .toolbar(removing: .sidebarToggle)
        } detail: {
            SettingsPane(
                category: navigation.category,
                provisioner: provisioner,
                graphics: graphics,
                storage: storage,
                engine: engine,
                shaders: shaders,
                compatibility: compatibility,
                diagnostics: diagnostics,
                steam: steam,
                highlighted: navigation.highlighted,
                requestedGame: $navigation.requestedGame,
                supervisor: supervisor,
                showReports: showReports,
            )
        }
        .navigationSplitViewStyle(.balanced)
        .environment(navigation)
        .onChange(of: navigation.category, initial: true) { navigation.noteCategoryShown() }
        .onChange(of: navigation.searchText.isEmpty) { navigation.noteSearchChanged() }
    }
}

// MARK: - Categories

enum SettingsCategory: String, CaseIterable, Identifiable {
    case general
    case graphics
    case engine
    case games
    case hoyoverse
    case storage
    case recovery
    case diagnostics
    case about

    var id: String {
        rawValue
    }

    var title: String {
        let key = switch self {
        case .general: "General"
        case .graphics: "Graphics"
        case .engine: "Engine"
        case .games: "Games"
        case .hoyoverse: "HoYoverse"
        case .storage: "Storage"
        case .recovery: "Recovery"
        case .diagnostics: "Diagnostics"
        case .about: "About"
        }
        return InterfaceCopy.localized(key)
    }

    var icon: String {
        switch self {
        case .general: "gearshape.fill"
        case .graphics: "cpu.fill"
        case .engine: "wrench.and.screwdriver.fill"
        case .games: "gamecontroller.fill"
        case .hoyoverse: "arrow.down.circle.fill"
        case .storage: "internaldrive.fill"
        case .recovery: "cross.case.fill"
        case .diagnostics: "stethoscope"
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
                    title: "Steam settings",
                    keywords: ["steam", "settings", "downloads", "controller", "interface"],
                ),
                SearchableSetting(
                    id: .generalSteamLinks,
                    title: "Steam links",
                    keywords: ["steam", "link", "links", "url", "install", "invitation", "browser", "web", "open"],
                ),
                SearchableSetting(
                    id: .generalCli,
                    title: "Command-line tool",
                    keywords: ["cli", "sevo", "command", "terminal", "path"],
                ),
                SearchableSetting(
                    id: .generalCompatStrip,
                    title: "Mac compatibility strip",
                    keywords: [
                        "compatibility", "compat", "strip", "badge", "verified",
                        "playable", "anti-cheat", "anticheat", "game page", "library",
                    ],
                ),
                SearchableSetting(
                    id: .generalCustomStyle,
                    title: "Custom style",
                    keywords: [
                        "css", "theme", "style", "stylesheet", "skin", "appearance", "color",
                        "font", "look", "custom", "store", "community",
                    ],
                ),
                SearchableSetting(
                    id: .generalStreamerMode,
                    title: "Streamer Mode",
                    keywords: [
                        "streamer", "streaming", "recording", "record", "privacy", "hide", "name",
                        "avatar", "picture", "wallet", "balance", "friends", "screen",
                    ],
                ),
                SearchableSetting(
                    id: .generalShareRuns,
                    title: "Share run statistics",
                    keywords: [
                        "community", "database", "share", "statistics", "stats", "frame rate", "fps",
                        "privacy", "telemetry", "delete", "upload",
                    ],
                ),
                SearchableSetting(
                    id: .generalDiscordBridge,
                    title: "Discord presence in games",
                    keywords: ["discord", "presence", "rich presence", "status", "bridge", "rpc"],
                ),
                SearchableSetting(
                    id: .generalDiscordPresence,
                    title: "Show what you play in Discord",
                    keywords: ["discord", "presence", "playing", "status", "activity"],
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
                    title: "Renderer",
                    keywords: [
                        "renderer", "graphics", "direct3d", "d3d", "d3dmetal",
                        "dxmt", "dxvk", "wined3d", "gpu", "metal",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsGpu,
                    title: "GPU reported to games",
                    keywords: [
                        "gpu", "graphics card", "nvidia", "geforce", "amd", "radeon",
                        "vendor", "driver", "outdated", "unsupported",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsShaders,
                    title: "Upscalers",
                    keywords: [
                        "upscaler", "upscale", "shader", "package", "anime4k", "cunny",
                        "neural", "pixel art", "anime", "visual novel", "download", "license",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsWindows,
                    title: "Resizable windows",
                    keywords: [
                        "window", "resizable", "resize", "move", "fullscreen",
                        "full screen", "fixed", "scale",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsUpscaler,
                    title: "Upscaler",
                    keywords: [
                        "upscaler", "upscale", "lanczos", "metalfx", "shader",
                        "anime4k", "cunny", "resolution", "sharp",
                    ],
                ),
                SearchableSetting(
                    id: .graphicsFilter,
                    title: "Final filter",
                    keywords: ["filter", "nearest", "bilinear", "lanczos", "resample", "pixel"],
                ),
                SearchableSetting(
                    id: .graphicsMouse,
                    title: "Mouse-look movement",
                    keywords: [
                        "mouse", "pointer", "cursor", "acceleration", "linear",
                        "sensitivity", "aim", "mouse-look", "fps", "movement",
                    ],
                ),
            ]
        case .engine:
            [
                SearchableSetting(
                    id: .engineSelection,
                    title: "Wine engine and bottle",
                    keywords: [
                        "engine", "wine", "crossover", "preview", "bottle",
                        "prefix", "built-in", "builtin", "dormison", "switch",
                        "update", "updates", "release",
                    ],
                ),
                SearchableSetting(
                    id: .engineMsync,
                    title: "Enhanced synchronization (msync+)",
                    keywords: [
                        "msync", "msync+", "sync", "synchronization", "performance",
                        "deadlock", "hang", "esync",
                    ],
                ),
                SearchableSetting(
                    id: .engineKnownFixes,
                    title: "Apply known fixes automatically",
                    keywords: [
                        "fix", "fixes", "known", "automatic", "first launch", "protonfixes",
                        "recommended", "quirk", "undo",
                    ],
                ),
                SearchableSetting(
                    id: .engineDependencies,
                    title: "Game dependencies",
                    keywords: [
                        "dependency", "vcruntime", "msvcp140", "vcredist", "vc++",
                        "redist", "fonts", "corefonts", "directx", "d3dx9",
                        "xaudio", "xact", "japanese", "chinese", "korean",
                        "winetricks", "missing", "dll",
                    ],
                ),
                SearchableSetting(
                    id: .engineOverrides,
                    title: "DLL overrides",
                    keywords: ["dll", "override", "native", "builtin", "library"],
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
        case .hoyoverse:
            [
                SearchableSetting(
                    id: .hoyoverseGames,
                    title: "HoYoverse games",
                    keywords: [
                        "hoyoverse", "hoyoplay", "genshin", "star rail", "honkai", "zenless", "zzz",
                        "update", "patch", "verify", "repair",
                    ],
                ),
                SearchableSetting(
                    id: .hoyoverseInstall,
                    title: "Install a HoYoverse game",
                    keywords: ["hoyoverse", "install", "download", "genshin", "star rail", "zenless", "voice"],
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
        case .recovery:
            [
                SearchableSetting(
                    id: .recoveryRestartSteam,
                    title: "Restart Steam",
                    keywords: ["restart", "steam", "reboot", "relaunch", "reopen", "frozen", "stuck"],
                ),
                SearchableSetting(
                    id: .recoveryForceQuit,
                    title: "Force Quit Steam",
                    keywords: ["force", "quit", "kill", "unresponsive", "hung", "frozen", "stuck"],
                ),
                SearchableSetting(
                    id: .recoveryCancelMenus,
                    title: "Dismiss stuck Steam menus",
                    keywords: [
                        "menu", "menus", "stuck", "frozen", "hang", "hung",
                        "menu bar", "tracking", "macos 27", "cancel", "dismiss",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryHelper,
                    title: "Repair the background helper",
                    keywords: [
                        "background", "helper", "daemon", "supervision", "login items",
                        "launch", "register", "repair",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryBottleRepair,
                    title: "Repair Steam",
                    keywords: [
                        "repair", "bottle", "windows", "components", "provision",
                        "reinstall", "setup", "fix", "broken",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryShaderCompiler,
                    title: "Direct3D shader compiler",
                    keywords: [
                        "d3dcompiler", "shader", "compiler", "direct3d", "d3d",
                        "missing", "dll", "reinstall",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryWineRestart,
                    title: "Restart Windows",
                    keywords: [
                        "wine", "wineserver", "windows", "restart", "cold", "machine",
                        "reboot", "fresh",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryClearShaderCache,
                    title: "Clear the shader cache",
                    keywords: [
                        "shader", "cache", "clear", "black screen", "pipeline",
                        "dxmt", "dxvk", "reset", "stuck load",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryRebuildSteam,
                    title: "Rebuild the bottle",
                    keywords: [
                        "rebuild", "reinstall", "steam", "client", "environment", "bottle",
                        "corrupt", "damaged", "broken", "fresh",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryWinecfg,
                    title: "Wine configuration",
                    keywords: ["wine", "winecfg", "windows version", "configuration", "recovery"],
                ),
            ]
        case .diagnostics:
            [
                SearchableSetting(
                    id: .diagnosticsLevel,
                    title: "Record",
                    keywords: [
                        "diagnostics", "level", "logging", "verbose", "trace", "seh",
                        "wine", "channels", "loaddll", "record", "run",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsDebugMode,
                    title: "Debug mode",
                    keywords: [
                        "debug", "verbose", "logging", "trace", "logs", "diagnostics",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsWineLog,
                    title: "Log every library a game loads",
                    keywords: [
                        "wine", "diagnostics", "log", "logging", "debug",
                        "winedebug", "trace", "error", "crash", "library", "dll", "loaddll",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsReports,
                    title: "Run reports",
                    keywords: [
                        "report", "reports", "crash", "collected", "folder", "finder",
                        "dump", "minidump", "ips", "share", "runs", "run", "history",
                        "issue", "github", "bug", "fps", "frame rate",
                        "cap", "caps", "limit", "size", "disk", "space", "rotation", "months", "budget",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsSave,
                    title: "Diagnostics archive",
                    keywords: [
                        "diagnostics", "diagnostic", "save", "logs", "log", "zip",
                        "bug", "crash", "support", "send",
                        "report", "guide", "how", "steps", "reproduce", "compare", "benchmark", "useful",
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
                    title: "Save Diagnostics",
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

    init(id: SettingsAnchor, title: String, keywords: [String]) {
        self.id = id
        self.title = InterfaceCopy.localized(title)
        self.keywords = keywords
    }

    func matches(_ search: String) -> Bool {
        title.localizedStandardContains(search) || keywords.contains { $0.localizedStandardContains(search) }
    }
}

/// Every row search can send someone to. A pane marks its row
/// (``SwiftUI/View/highlightable(_:highlighted:)``) and
/// ``SettingsCategory/searchableItems`` names it; `SettingsSearchTests`
/// fails if the two sets drift.
enum SettingsAnchor: String, CaseIterable {
    case generalOpenAtLogin = "general.openAtLogin"
    case generalSteamSettings = "general.steamSettings"
    case generalSteamLinks = "general.steamLinks"
    case generalCli = "general.cli"
    case generalCompatStrip = "general.compatStrip"
    case generalCustomStyle = "general.customStyle"
    case generalStreamerMode = "general.streamerMode"
    case generalShareRuns = "general.shareRuns"
    case generalDiscordBridge = "general.discordBridge"
    case generalDiscordPresence = "general.discordPresence"
    case generalAgents = "general.agents"
    case generalUninstall = "general.uninstall"
    case graphicsRenderer = "graphics.renderer"
    case graphicsGpu = "graphics.gpu"
    case graphicsShaders = "graphics.shaders"
    case graphicsWindows = "graphics.windows"
    case graphicsUpscaler = "graphics.upscaler"
    case graphicsFilter = "graphics.filter"
    case graphicsMouse = "graphics.mouse"
    case engineSelection = "engine.selection"
    case engineMsync = "engine.msync"
    case engineKnownFixes = "engine.knownFixes"
    case engineDependencies = "engine.dependencies"
    case engineOverrides = "engine.overrides"
    case gamesSettings = "games.settings"
    case gamesUpscaler = "games.upscaler"
    case hoyoverseGames = "hoyoverse.games"
    case hoyoverseInstall = "hoyoverse.install"
    case storageGames = "storage.games"
    case storageSharing = "storage.sharing"
    case recoveryRestartSteam = "recovery.restartSteam"
    case recoveryForceQuit = "recovery.forceQuit"
    case recoveryCancelMenus = "recovery.cancelMenus"
    case recoveryHelper = "recovery.helper"
    case recoveryBottleRepair = "recovery.bottleRepair"
    case recoveryShaderCompiler = "recovery.shaderCompiler"
    case recoveryWineRestart = "recovery.wineRestart"
    case recoveryClearShaderCache = "recovery.clearShaderCache"
    case recoveryRebuildSteam = "recovery.rebuildSteam"
    case recoveryWinecfg = "recovery.winecfg"
    case diagnosticsLevel = "diagnostics.level"
    case diagnosticsDebugMode = "diagnostics.debugMode"
    case diagnosticsWineLog = "diagnostics.wineLog"
    case diagnosticsReports = "diagnostics.reports"
    case diagnosticsSave = "diagnostics.save"
    case aboutDiagnostics = "about.diagnostics"
    case aboutVersion = "about.version"
}

// MARK: - Sidebar

struct SettingsSidebar: View {
    @Binding var category: SettingsCategory
    @Binding var searchText: String
    @Binding var highlighted: SettingsAnchor?

    /// One row per matching setting, with its pane. Never group the results
    /// with `Section`: header rows beside content rows make AppKit's table
    /// raise a layout exception, crashing the app, when results change under
    /// a live selection.
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

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        List(selection: $category) {
            if searchText.isEmpty {
                // White on the gold selection of a key window is hard to read.
                ForEach(SettingsCategory.allCases) { item in
                    Label(item.title, systemImage: item.icon)
                        .foregroundStyle(
                            item == category && controlActiveState != .inactive
                                ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.primary),
                        )
                        .tag(item)
                }
            } else {
                ForEach(matches) { match in
                    Button { reveal(match.item, in: match.category) } label: {
                        // Stacked: side by side, the sidebar truncates both.
                        Label {
                            VStack(alignment: .leading, spacing: SettingsMetrics.popoverTermGap) {
                                Text(match.item.title)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(match.category.title)
                                    .font(SettingsType.legend)
                                    .foregroundStyle(.secondary)
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
        .frame(minWidth: SettingsMetrics.sidebar)
    }

    /// Opens the setting's pane and flashes its row for a moment; a later
    /// pick owns the light.
    private func reveal(_ item: SearchableSetting, in category: SettingsCategory) {
        self.category = category
        highlighted = item.id
        Task(name: "Clear settings highlight") {
            try? await Task.sleep(for: SettingsMetrics.highlight)
            if highlighted == item.id { highlighted = nil }
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
    let diagnostics: DiagnosticsStore
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @Binding var requestedGame: SettingsNavigation.GameRequest?
    var supervisor: ClientSupervisor?
    var showReports: (() -> Void)?

    var body: some View {
        Group {
            switch category {
            case .general:
                GeneralSettings(
                    provisioner: provisioner, store: storage, steam: steam,
                    highlighted: highlighted, supervisor: supervisor,
                )
            case .graphics:
                GraphicsSettings(
                    store: graphics, shaders: shaders,
                    defaults: Engine.active.isCrossOver ? nil : engine.bottleDefaults,
                    steam: steam, highlighted: highlighted,
                )
            case .engine:
                EngineSettings(
                    store: engine, graphics: graphics, shaders: shaders, compatibility: compatibility,
                    provisioner: provisioner, highlighted: highlighted,
                )
            case .games:
                GamesSettings(shaders: shaders, highlighted: highlighted, requestedGame: $requestedGame)
            case .hoyoverse:
                HoYoSettings(highlighted: highlighted)
            case .storage:
                StorageSettings(store: storage, steam: steam, highlighted: highlighted)
            case .recovery:
                RecoverySettings(
                    provisioner: provisioner, compatibility: compatibility,
                    supervisor: supervisor, steam: steam, highlighted: highlighted,
                )
            case .diagnostics:
                DiagnosticsSettings(store: diagnostics, highlighted: highlighted, showReports: showReports)
            case .about: AboutSettings(highlighted: highlighted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The toolbar's safe area fits a title and subtitle; the form runs
        // under the titlebar and this bar holds back only the title's height,
        // giving the soft edge effect a bar to fade under.
        .safeAreaBar(edge: .top) {
            Color.clear.frame(height: SettingsMetrics.titleBar)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(category.title)
        .ignoresSafeArea(edges: .vertical)
    }
}
