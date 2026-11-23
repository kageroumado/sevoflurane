import SwiftUI
import UniformTypeIdentifiers

/// Settings › Games: the installed games and adopted programs with a settings
/// file, and the values the selected one sets over the bottle's. A file is made
/// at a game's first launch and kept through an uninstall; writes take the path
/// `sevo app config` takes.
struct GamesSettings: View {
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @State private var games: [Entry] = []
    @State private var selected: Int?
    /// Opens on the first game, for the gallery.
    var selectsFirstGame = false
    /// The gallery's games, shown on a Mac that has none of its own.
    var fixtureGames: [Entry] = []
    /// The gallery's settings for the selected game, in place of the Mac's.
    var fixtureForm: SettingsStore?
    /// Draws the sections an adopted program has, for the gallery.
    var showsProgramSections = false
    /// A game requested from elsewhere (a game's menu in the popover); taken
    /// and cleared.
    var requestedGame: Binding<SettingsNavigation.GameRequest?> = .constant(nil)
    /// What the fix table says about the selected game.
    @State private var recommendation = KnownFixes.Recommendation(fixes: [])
    /// The selected game's settings, made when the selection changes.
    @State private var form: SettingsStore?

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let exes: [String]
    }

    var body: some View {
        SettingsSplit {
            List(games, selection: Binding(get: { selected }, set: { select($0) })) { entry in
                SettingsListRow(
                    title: entry.name,
                    detail: entry.exes.isEmpty
                        ? String(localized: "not launched here yet") : entry.exes.joined(separator: ", "),
                )
            }
        } detail: {
            if let selected, let entry = games.first(where: { $0.id == selected }),
               let form, form.scope.game == entry.id {
                GameForm(
                    gameID: entry.id, name: entry.name, store: form, shaders: shaders,
                    highlighted: highlighted, recommendation: recommendation,
                    showsProgramSections: showsProgramSections,
                )
                // A store belongs to one game, so another game is another form.
                .id(entry.id)
            } else {
                GamesPlaceholder(hasGames: !games.isEmpty)
            }
        }
        .onAppear {
            reload()
            takeRequest()
        }
        .onChange(of: requestedGame.wrappedValue) { takeRequest() }
    }

    /// Selects the requested game. One never launched has no file and joins the
    /// list; its first setting writes the file.
    private func takeRequest() {
        guard let request = requestedGame.wrappedValue else { return }
        requestedGame.wrappedValue = nil
        if !games.contains(where: { $0.id == request.id }) {
            games.append(Entry(id: request.id, name: request.name, exes: []))
            games.sort(by: Self.byName)
        }
        select(request.id)
    }

    /// Selects a game and reads what its form shows; the same game again
    /// keeps the form it has.
    private func select(_ id: Int?) {
        selected = id
        recommendation = id.map {
            KnownFixes.recommended(for: $0, exes: GameConfig.game($0).exes ?? [])
        } ?? KnownFixes.Recommendation(fixes: [])
        guard let id else {
            form = nil
            return
        }
        if form?.scope.game != id {
            form = fixtureForm.flatMap { $0.scope.game == id ? $0 : nil }
                ?? SettingsStore(scope: .game(id, bottle: SteamBottle.name))
        }
    }

    /// By name, then id, so unnamed games keep a stable order.
    private static func byName(_ a: Entry, _ b: Entry) -> Bool {
        let order = a.name.localizedStandardCompare(b.name)
        return order == .orderedSame ? a.id < b.id : order == .orderedAscending
    }

    private func reload() {
        let installed = SharedGames.installedAppIDs
        games = GameConfig.games()
            .filter { id, _ in installed.contains(id) || AdoptedPrograms.isAdopted(id) }
            .map { id, values in
                Entry(id: id, name: values.name ?? "App \(id)", exes: values.exes ?? [])
            }
            .sorted(by: Self.byName)
        if games.isEmpty || fixtureForm != nil { games = fixtureGames }
        var choice = selected.flatMap { id in games.contains { $0.id == id } ? id : nil }
        if selectsFirstGame, choice == nil { choice = games.first?.id }
        select(choice)
    }
}

private struct GamesPlaceholder: View {
    let hasGames: Bool

    /// In a scroll view, so the toolbar draws the same edge over this side as over the list
    /// and form.
    var body: some View {
        GeometryReader { pane in
            ScrollView {
                message.frame(width: pane.size.width, height: pane.size.height)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    @ViewBuilder private var message: some View {
        if hasGames {
            ContentUnavailableView(
                "Choose a game", systemImage: "gamecontroller",
                description: Text("Customize its window, upscaler, and mouse settings."),
            )
        } else {
            ContentUnavailableView(
                "No games yet", systemImage: "gamecontroller",
                description: Text("Games appear here after their first launch."),
            )
        }
    }
}

// MARK: - The form

/// The selected game's form: the catalog's groups at the game level, then its DLL
/// overrides and environment, all through one store.
private struct GameForm: View {
    let gameID: Int
    let name: String
    let store: SettingsStore
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    let recommendation: KnownFixes.Recommendation
    let showsProgramSections: Bool

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            SettingSections(
                store: store, shaders: shaders, highlighted: highlighted,
                heading: name, recommendation: recommendation,
            )
            GameDLLOverridesSection(store: store)
            EnvironmentSection(store: store)
            if let appliedFixes = store.appliedFixes, !appliedFixes.keys(in: store.values).isEmpty {
                FixListSection(fixes: appliedFixes, settings: appliedFixes.keys(in: store.values)) {
                    store.undoFixes(nil)
                }
            }
            if let program = AdoptedPrograms.program(gameID) {
                if SteamLibraryShortcuts.canList(program) {
                    SteamLibrarySection(programID: gameID)
                }
                if FPSUnlocker.games.contains(program.url.lastPathComponent.lowercased()) {
                    FPSUnlockerSection()
                }
            } else if showsProgramSections {
                SteamLibrarySection(programID: gameID)
                FPSUnlockerSection()
            }
            DockSection(gameID: gameID)
        }
        .highlightableSection(.gamesSettings, highlighted: highlighted)
    }
}

// MARK: - The fix list

/// What the fix list set at the first launch and still holds, with one undo:
/// the native runner and DLL overrides have no row of their own to carry the
/// mark.
private struct FixListSection: View {
    let fixes: AppliedFixes
    /// The stored names of the keys the fix list still holds.
    let settings: [String]
    let undo: () -> Void

    var body: some View {
        SettingsSection(
            title: "Set by the fix list",
            footer: "Set at the game\u{2019}s first launch, where it had no value of its own.",
        ) {
            ForEach(fixes.fixes, id: \.title) { fix in
                SettingsRow(title: "\(fix.title)", caption: InterfaceCopy.localized(fix.reason)) {}
            }
            SettingsAction(title: "Values it holds", caption: remaining.joined(separator: ", ")) {
                Button("Undo Fixes", action: undo)
            }
        }
    }

    private var remaining: [String] {
        var held = fixes
        held.applied = ConfigValues(fields: fixes.applied.fields.filter { settings.contains($0.key) }) ?? .empty
        return held.settingNames
    }
}

// MARK: - Steam's library

/// Whether an adopted program is listed in Steam's library as a non-Steam game
/// (``SteamLibraryShortcuts``).
private struct SteamLibrarySection: View {
    let programID: Int
    /// The switch as last set here; the record until then.
    @State private var listed: Bool?

    var body: some View {
        SettingsSection(title: "Steam library") {
            SettingsToggle(
                title: "Show in Steam\u{2019}s library",
                caption: String(localized: "As a non-Steam game, with Steam Input and the overlay."),
                help: .steamLibrary,
                isOn: Binding(
                    get: { listed ?? (AdoptedPrograms.program(programID)?.inSteamLibrary == true) },
                    set: { isOn in
                        listed = isOn
                        SteamLibraryShortcuts.shared.setListed(isOn, programID: programID)
                    },
                ),
            )
        }
    }
}

// MARK: - The Dock

/// The game's own Dock tile (``DockTiles``). Its bundle exists once the game
/// has launched.
private struct DockSection: View {
    let gameID: Int
    @State private var bundle: URL?
    /// The switch as last set here; the Dock's own record until then.
    @State private var kept: Bool?

    var body: some View {
        SettingsSection(title: "Dock") {
            SettingsToggle(
                title: "Keep in Dock",
                caption: bundle == nil
                    ? String(localized: "Available after the game\u{2019}s first launch.")
                    : String(localized: "A click on its Dock icon starts the game."),
                help: .dockTile,
                isOn: Binding(
                    get: { kept ?? false },
                    set: { isOn in
                        guard let bundle else { return }
                        kept = isOn
                        Task.detached(name: isOn ? "Keep \(gameID) in the Dock" : "Take \(gameID) out of the Dock") {
                            if isOn { DockTiles.keep(bundle) } else { DockTiles.remove(bundle) }
                        }
                    },
                ),
            )
            .disabled(bundle == nil)
        }
        .task(id: gameID) {
            let facts = await Self.read(gameID)
            bundle = facts.bundle
            kept = facts.kept
        }
    }

    @concurrent
    private nonisolated static func read(_ gameID: Int) async -> (bundle: URL?, kept: Bool) {
        let bundle = GameLaunchers.dockableBundle(appID: gameID)
        return (bundle, bundle.map(DockTiles.isKept) ?? false)
    }
}

// MARK: - Frame-rate unlocker

/// The unlocker Genshin Impact runs beside (``FPSUnlocker``): one for every
/// copy of the game, read by the helper at each launch.
private struct FPSUnlockerSection: View {
    @State private var executable = FPSUnlocker.executable
    @State private var isEnabled = FPSUnlocker.isEnabled
    @State private var target = FPSUnlocker.target

    var body: some View {
        SettingsSection(
            title: "FPS unlocker",
            footer: "An unlocker changes the running game\u{2019}s memory, which HoYoverse\u{2019}s terms do not allow, so the switch is yours.",
        ) {
            SettingsAction(title: "Unlocker", help: .fpsUnlocker) {
                SettingsValueText(text: executable?.lastPathComponent ?? ownLabel)
                Button("Choose…", action: choose)
                if executable != nil {
                    Button(hasOwn ? "Use Sevoflurane\u{2019}s" : "Remove") {
                        executable = nil
                        FPSUnlocker.executable = nil
                    }
                }
            }
            SettingsToggle(title: "Start it with the game", isOn: $isEnabled)
                .disabled(executable == nil && !hasOwn)
                .onChange(of: isEnabled) { _, on in FPSUnlocker.isEnabled = on }
            SettingsPicker(title: "Frame rate", selection: $target) {
                ForEach(targets, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
            }
            .disabled(executable == nil && !hasOwn)
            .onChange(of: target) { _, fps in FPSUnlocker.target = fps }
        }
    }

    private var hasOwn: Bool { Engine.active.fpsUnlocker != nil }

    private var ownLabel: String {
        hasOwn ? String(localized: "Sevoflurane\u{2019}s own") : String(localized: "None")
    }

    /// The offered rates, plus the stored one if missing.
    private var targets: [Int] {
        FPSUnlocker.targets.contains(target) ? FPSUnlocker.targets : (FPSUnlocker.targets + [target]).sorted()
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose the FPS Unlocker")
        panel.prompt = String(localized: "Choose")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let exe = UTType("com.microsoft.windows-executable") {
            panel.allowedContentTypes = [exe]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        executable = url
        FPSUnlocker.executable = url
        if !isEnabled {
            isEnabled = true
        }
    }
}
