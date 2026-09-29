import Propofol
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
    /// Ends a stuck menu-bar tracking session, answering which root menus were
    /// open — the way out of the macOS 27 menu hang from Settings.
    var cancelStuckMenus: () -> [String]
    /// Draws or removes the Mac compatibility strip on the game page that is
    /// already open, so the switch shows its result where it is about.
    var applyCompatibilityStrip: () -> Void
    /// Reloads Steam's pages so they carry the Streamer Mode mask, or lose it.
    var applyStreamerMode: () -> Void
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
    let compatibility: CompatibilityStore
    var steam: SteamActions?
    /// Stood down by the General pane's uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    /// Opens the report window, which lives beside Settings rather than in
    /// it. Absent in the gallery, where no second window opens.
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
                steam: steam,
                highlighted: navigation.highlighted,
                requestedGame: $navigation.requestedGame,
                supervisor: supervisor,
                showReports: showReports,
            )
        }
        .navigationSplitViewStyle(.balanced)
        .onChange(of: navigation.category, initial: true) { _, category in
            EventLog.shared.log(.window, "settings: showing \(category.title)")
        }
        .onChange(of: navigation.searchText.isEmpty) { _, isEmpty in
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
                    title: "Steam's own settings",
                    keywords: ["steam", "settings", "downloads", "controller", "interface"],
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
                        "update", "updates", "channel", "beta", "release",
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
                    id: .engineWindows,
                    title: "Resizable windows",
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
        case .recovery:
            [
                SearchableSetting(
                    id: .recoveryRestartSteam,
                    title: "Restart Steam",
                    keywords: ["restart", "steam", "reboot", "relaunch", "reopen", "frozen", "stuck"],
                ),
                SearchableSetting(
                    id: .recoveryForceQuit,
                    title: "Force-quit Steam",
                    keywords: ["force", "quit", "kill", "unresponsive", "hung", "frozen", "stuck"],
                ),
                SearchableSetting(
                    id: .recoveryCancelMenus,
                    title: "Cancel stuck menus",
                    keywords: [
                        "menu", "menus", "stuck", "frozen", "hang", "hung",
                        "menu bar", "tracking", "macos 27",
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
                    title: "Repair Windows components",
                    keywords: [
                        "repair", "bottle", "windows", "components", "provision",
                        "reinstall", "setup", "fix", "broken",
                    ],
                ),
                SearchableSetting(
                    id: .recoveryShaderCompiler,
                    title: "Reinstall the Direct3D shader compiler",
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
                    title: "Rebuild the Steam environment",
                    keywords: [
                        "rebuild", "reinstall", "steam", "client", "environment",
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
                    title: "How much a run records",
                    keywords: [
                        "diagnostics", "level", "logging", "verbose", "trace", "seh",
                        "wine", "channels", "loaddll", "record", "run",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsGuide,
                    title: "Making a useful report",
                    keywords: [
                        "report", "bug", "guide", "how", "steps", "reproduce", "compare",
                        "benchmark", "performance", "fps", "frame rate", "useful",
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
                    id: .diagnosticsReports,
                    title: "Run reports",
                    keywords: [
                        "report", "reports", "crash", "collected", "folder", "finder",
                        "dump", "minidump", "ips", "share", "runs", "run", "history",
                        "issue", "github", "bug", "fps", "frame rate",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsSave,
                    title: "Diagnostics archive",
                    keywords: [
                        "diagnostics", "diagnostic", "save", "logs", "log", "zip",
                        "bug", "crash", "support", "send",
                    ],
                ),
                SearchableSetting(
                    id: .diagnosticsCaps,
                    title: "What diagnostics may take",
                    keywords: [
                        "cap", "caps", "limit", "size", "disk", "space", "rotation",
                        "months", "budget",
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

    init(id: SettingsAnchor, title: String, keywords: [String]) {
        self.id = id
        self.title = InterfaceCopy.localized(title)
        self.keywords = keywords
    }

    func matches(_ search: String) -> Bool {
        title.localizedStandardContains(search) || keywords.contains { $0.localizedStandardContains(search) }
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
    case generalCompatStrip = "general.compatStrip"
    case generalStreamerMode = "general.streamerMode"
    case generalShareRuns = "general.shareRuns"
    case generalDiscordBridge = "general.discordBridge"
    case generalDiscordPresence = "general.discordPresence"
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
    case diagnosticsGuide = "diagnostics.guide"
    case diagnosticsDebugMode = "diagnostics.debugMode"
    case diagnosticsReports = "diagnostics.reports"
    case diagnosticsSave = "diagnostics.save"
    case diagnosticsCaps = "diagnostics.caps"
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

    @Environment(\.controlActiveState) private var controlActiveState

    var body: some View {
        List(selection: $category) {
            if searchText.isEmpty {
                // The sidebar tints a row's icon itself. On the selected row of a key
                // window the fill is the gold accent, where the system's white label is
                // hard to read; an inactive window's selection is gray and keeps its own.
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
                        // The pane under the setting's name: side by side, the
                        // sidebar's width truncates both to a few letters.
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(match.item.title)
                                    .foregroundStyle(.primary)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(match.category.title)
                                    .font(.caption)
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
        .frame(minWidth: 190)
    }

    /// Opens the setting's pane and flashes its row, long enough to find with
    /// the eye and short enough not to stay behind as decoration. A later
    /// pick owns the light, so an earlier one's timer leaves it on.
    private func reveal(_ item: SearchableSetting, in category: SettingsCategory) {
        self.category = category
        highlighted = item.id
        Task(name: "Clear settings highlight") {
            try? await Task.sleep(for: .seconds(1.8))
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
                GraphicsSettings(store: graphics, shaders: shaders, steam: steam, highlighted: highlighted)
            case .engine:
                EngineSettings(
                    store: engine, graphics: graphics, shaders: shaders, compatibility: compatibility,
                    provisioner: provisioner, highlighted: highlighted,
                )
            case .games:
                GamesSettings(shaders: shaders, highlighted: highlighted, requestedGame: $requestedGame)
            case .storage:
                StorageSettings(store: storage, steam: steam, highlighted: highlighted)
            case .recovery:
                RecoverySettings(
                    provisioner: provisioner, compatibility: compatibility,
                    supervisor: supervisor, steam: steam, highlighted: highlighted,
                )
            case .diagnostics:
                DiagnosticsSettings(highlighted: highlighted, showReports: showReports)
            case .about: AboutSettings(highlighted: highlighted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The toolbar's safe area is sized for a title and a subtitle, and a
        // pane has only the title. The form runs under the titlebar and this
        // bar holds back just the title's height; it needs content to exist,
        // and the soft edge effect needs a bar to fade under.
        .safeAreaBar(edge: .top) {
            Text(" ").frame(width: 1, height: 42)
        }
        .scrollEdgeEffectStyle(.soft, for: .all)
        .navigationTitle(category.title)
        .ignoresSafeArea(edges: .vertical)
    }
}

/// A control with its caption under the whole row. A caption inside a
/// picker's own label shares the row with the value, and a long value leaves
/// it a column a few words wide.
struct CaptionedRow<Control: View>: View {
    let caption: String
    /// Orange for a caption that reports a failure.
    var isWarning = false
    @ViewBuilder var control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            control
            if !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Flashes a row the search sent the user to.
private struct HighlightModifier: ViewModifier {
    let anchor: SettingsAnchor?
    let highlighted: SettingsAnchor?

    func body(content: Content) -> some View {
        // The light spreads past the row instead of the row making room for
        // it, so a row search can reach lines up with one it cannot.
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isLit ? Color.accentColor.opacity(0.2) : .clear)
                    .padding(.horizontal, -Theme.Space.sm)
                    .padding(.vertical, -Theme.Space.xs)
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
    /// gives it nothing to light up for.
    func highlightable(_ anchor: SettingsAnchor?, highlighted: SettingsAnchor?) -> some View {
        modifier(HighlightModifier(anchor: anchor, highlighted: highlighted))
    }
}
