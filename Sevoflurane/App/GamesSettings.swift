import SwiftUI
import UniformTypeIdentifiers

/// Settings › Games: the installed games and adopted programs with a file in
/// the settings hierarchy, and for the selected one the values it sets over
/// the bottle's. A game gets a file at its first launch, when its executables
/// are recorded, and keeps it through an uninstall, so its settings are there
/// when it comes back. Writes take the path `sevo app config` takes.
struct GamesSettings: View {
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @State private var games: [Entry] = []
    @State private var selected: Int?
    /// Opens on the first game, for the gallery, which has nobody to pick one.
    var selectsFirstGame = false
    /// A game someone asked to see from elsewhere — a game's menu in the
    /// popover. Taken and cleared.
    var requestedGame: Binding<SettingsNavigation.GameRequest?> = .constant(nil)
    /// What the fix table says about the selected game.
    @State private var recommendation = KnownFixes.Recommendation(fixes: [])

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let exes: [String]
    }

    var body: some View {
        HStack(spacing: 0) {
            GameList(games: games, selected: $selected)
            Divider()
            if let selected, let entry = games.first(where: { $0.id == selected }) {
                GameForm(
                    gameID: entry.id, name: entry.name, shaders: shaders, highlighted: highlighted,
                    recommendation: recommendation,
                )
                // A store belongs to one game: another game is another form.
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
        .onChange(of: selected) { _, id in
            select(id)
        }
    }

    /// Selects the requested game. One that has never launched has no file
    /// yet and is not in the list; it joins it, and its first setting
    /// writes the file.
    private func takeRequest() {
        guard let request = requestedGame.wrappedValue else { return }
        requestedGame.wrappedValue = nil
        if !games.contains(where: { $0.id == request.id }) {
            games.append(Entry(id: request.id, name: request.name, exes: []))
            games.sort(by: Self.byName)
        }
        selected = request.id
    }

    /// Loads what the fix table says about a game.
    private func select(_ id: Int?) {
        recommendation = id.map {
            KnownFixes.recommended(for: $0, exes: GameConfig.game($0).exes ?? [])
        } ?? KnownFixes.Recommendation(fixes: [])
    }

    /// By name, then id, so two games without a name keep a stable order.
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
        if let selected, !games.contains(where: { $0.id == selected }) {
            self.selected = nil
        }
        if selectsFirstGame, selected == nil { selected = games.first?.id }
        select(selected)
    }
}

// MARK: - The list

/// The sidebar: one row per game, the selection the form follows.
private struct GameList: View {
    let games: [GamesSettings.Entry]
    @Binding var selected: Int?

    private static let width: CGFloat = 210

    var body: some View {
        List(games, selection: $selected) { entry in
            GameListRow(name: entry.name, exes: entry.exes)
        }
        .listStyle(.inset)
        .frame(width: Self.width)
    }
}

/// A game's name over the executables it is known to run under.
private struct GameListRow: View {
    let name: String
    let exes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(name).lineLimit(1)
            Text(exes.isEmpty ? String(localized: "not launched here yet") : exes.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// What the form's side shows while no game is selected.
private struct GamesPlaceholder: View {
    let hasGames: Bool

    /// In a scroll view, so the toolbar draws the same edge over this side as over the list
    /// and the form.
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

/// The selected game's form: the catalog's groups at the game level, then
/// its DLL overrides and its environment. Everything it changes goes through one store.
private struct GameForm: View {
    let gameID: Int
    let name: String
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    let recommendation: KnownFixes.Recommendation
    @State private var store: SettingsStore
    /// What the fix list set on this game at its first launch.
    @State private var appliedFixes: AppliedFixes?

    init(
        gameID: Int, name: String, shaders: ShaderStore, highlighted: SettingsAnchor?,
        recommendation: KnownFixes.Recommendation,
    ) {
        self.gameID = gameID
        self.name = name
        self.shaders = shaders
        self.highlighted = highlighted
        self.recommendation = recommendation
        _store = State(initialValue: SettingsStore(scope: .game(gameID, bottle: SteamBottle.name)))
        _appliedFixes = State(initialValue: FixLedger.record(for: gameID))
    }

    var body: some View {
        Form {
            SettingSections(
                store: store, shaders: shaders, highlighted: highlighted,
                heading: name, recommendation: recommendation,
                appliedFixes: appliedFixes, undoFix: { undoFixes([$0]) },
            )
            GameDLLOverridesSection(store: store)
            EnvironmentSection(store: store)
            if let appliedFixes, !appliedFixes.keys(in: store.values).isEmpty {
                FixListSection(fixes: appliedFixes, settings: appliedFixes.keys(in: store.values)) {
                    undoFixes(nil)
                }
            }
            if let program = AdoptedPrograms.program(gameID) {
                if SteamLibraryShortcuts.canList(program) {
                    SteamLibrarySection(programID: gameID)
                }
                if FPSUnlocker.games.contains(program.url.lastPathComponent.lowercased()) {
                    FPSUnlockerSection()
                }
            }
        }
        .formStyle(.grouped)
        .highlightable(.gamesSettings, highlighted: highlighted)
    }

    /// Puts `keys` (all of them when `nil`) back as they were before the fix
    /// list, the way the notification's Undo does.
    private func undoFixes(_ keys: Set<String>?) {
        appliedFixes = FixLedger.undo(appID: gameID, keys: keys, inBackground: true)
        store.reload()
    }
}

// MARK: - The fix list

/// What the fix list set on this game at its first launch and still holds,
/// with the undo for all of it: the native runner and DLL overrides have no
/// row of their own to carry the mark.
private struct FixListSection: View {
    let fixes: AppliedFixes
    /// The stored names of the keys the fix list still holds.
    let settings: [String]
    let undo: () -> Void

    var body: some View {
        Section {
            ForEach(fixes.fixes, id: \.title) { fix in
                VStack(alignment: .leading, spacing: 2) {
                    Text(fix.title)
                    Text(InterfaceCopy.localized(fix.reason))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            HStack {
                Text(remaining.joined(separator: ", "))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Undo", action: undo)
            }
        } header: {
            Text("Set by the fix list")
        } footer: {
            Text("Set at the game's first launch, where it had no value of its own. Undo puts back what it had.")
        }
    }

    /// The settings still held, in Settings' words.
    private var remaining: [String] {
        var held = fixes
        held.applied = ConfigValues(fields: fixes.applied.fields.filter { settings.contains($0.key) }) ?? .empty
        return held.settingNames
    }
}

// MARK: - Steam's library

/// Whether an adopted program is listed in Steam's library as a non-Steam
/// game (``SteamLibraryShortcuts``).
private struct SteamLibrarySection: View {
    let programID: Int
    /// The switch as last set here; the record until then.
    @State private var listed: Bool?

    var body: some View {
        Section {
            Toggle("Show in Steam's library", isOn: Binding(
                get: { listed ?? (AdoptedPrograms.program(programID)?.inSteamLibrary == true) },
                set: { isOn in
                    listed = isOn
                    SteamLibraryShortcuts.shared.setListed(isOn, programID: programID)
                },
            ))
        } footer: {
            Text("""
            Listed as a non-Steam game, it starts from Steam's library and Big Picture, with Steam Input and the \
            overlay, and keeps the settings, Dock tile and run records it has here.
            """)
        }
    }
}

// MARK: - Frame-rate unlocker

/// The unlocker Genshin Impact gets beside it (``FPSUnlocker``). One for
/// every copy of the game, so it is set here and read by the helper at each
/// launch.
private struct FPSUnlockerSection: View {
    @State private var executable = FPSUnlocker.executable
    @State private var isEnabled = FPSUnlocker.isEnabled
    @State private var target = FPSUnlocker.target

    var body: some View {
        Section {
            LabeledContent("Unlocker") {
                HStack(spacing: 6) {
                    Text(verbatim: executable?.lastPathComponent ?? ownLabel)
                        .foregroundStyle(executable == nil && !hasOwn ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(executable?.path ?? "")
                    Button("Choose…", action: choose)
                    if executable != nil {
                        Button(hasOwn ? "Use Sevoflurane's" : "Remove") {
                            executable = nil
                            FPSUnlocker.executable = nil
                        }
                    }
                }
            }
            Toggle("Start it with the game", isOn: $isEnabled)
                .disabled(executable == nil && !hasOwn)
                .onChange(of: isEnabled) { _, on in FPSUnlocker.isEnabled = on }
            Picker("Frame rate", selection: $target) {
                ForEach(targets, id: \.self) { Text(verbatim: "\($0) fps").tag($0) }
            }
            .disabled(executable == nil && !hasOwn)
            .onChange(of: target) { _, fps in FPSUnlocker.target = fps }
        } header: {
            Text("FPS unlocker")
        } footer: {
            Text("""
            Genshin holds itself to 60 fps. Sevoflurane's engine carries an unlocker (genshin-fps-unlock's, MIT); \
            switched on, it starts beside the game 30 seconds after the game's process appears. Choose another, such as \
            unlockfps_nc.exe, to use that one instead. An unlocker changes the running game's memory, which \
            HoYoverse's terms do not allow, so the switch is yours.
            """)
        }
    }

    /// Whether the active engine carries its own unlocker.
    private var hasOwn: Bool { Engine.active.fpsUnlocker != nil }

    private var ownLabel: String {
        hasOwn ? String(localized: "Sevoflurane's own") : String(localized: "None")
    }

    /// The offered rates, and the stored one if it is not among them.
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

// MARK: - DLL overrides

/// The load order this game gives named DLLs, over the bottle's own
/// overrides. Written under `AppDefaults\<exe>\DllOverrides`, so a game
/// can take a native runtime the rest of the bottle does not.
private struct GameDLLOverridesSection: View {
    let store: SettingsStore

    var body: some View {
        let table = (store.values.dllOverrides ?? [:]).sorted { $0.key < $1.key }
        Section {
            ForEach(table, id: \.key) { library, order in
                DLLOverrideRow(dll: library, mode: order) {
                    store.send(.setDLLOverride(library: library, order: $0))
                }
            }
            AddDLLOverrideRow { library, order in
                store.send(.setDLLOverride(library: library, order: order))
            }
        } header: {
            HStack(spacing: 6) {
                Text("DLL overrides")
                SettingHelpButton(help: SettingCopy.dllOverrides)
            }
        } footer: {
            Text("For this game alone, from its next launch. winecfg shows the same values; Settings › Engine holds the bottle's.")
        }
    }
}

/// Wine's load orders in the spelling the registry holds, so the picker
/// and `sevo app config <id> dll` name the same values.
private let dllOverrideModes: [(mode: String, label: LocalizedStringResource)] = [
    ("n,b", "Native, then built-in"),
    ("b,n", "Built-in, then native"),
    ("n", "Native only"),
    ("b", "Built-in only"),
    ("", "Disabled"),
]

/// One overridden DLL: its load order, and the button that takes the
/// override away.
private struct DLLOverrideRow: View {
    let dll: String
    let mode: String
    /// Writes a load order for this DLL; `nil` removes the override.
    let set: (String?) -> Void

    var body: some View {
        HStack {
            Text(dll).font(.body.monospaced())
            Spacer()
            Picker("Load order", selection: Binding(get: { mode }, set: { set($0) })) {
                ForEach(dllOverrideModes, id: \.mode) { choice in
                    Text(choice.label).tag(choice.mode)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button {
                set(nil)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove the override for \(dll)")
            .accessibilityLabel("Remove the override for \(dll)")
        }
    }
}

/// The row that names a DLL and a load order and adds the pair.
private struct AddDLLOverrideRow: View {
    let add: (_ dll: String, _ mode: String) -> Void
    @State private var name = ""
    @State private var mode = "n,b"
    @State private var libraries: [String] = []

    var body: some View {
        // Two lines: the form's column is too narrow for a library name, a
        // load order and a button side by side.
        VStack(alignment: .leading, spacing: 8) {
            DLLNameField(name: $name, names: libraries)
            HStack {
                Picker("Load order", selection: $mode) {
                    ForEach(dllOverrideModes, id: \.mode) { choice in
                        Text(choice.label).tag(choice.mode)
                    }
                }
                .labelsHidden()
                .fixedSize()
                Spacer()
                Button("Add") {
                    let dll = BuiltinLibraries.normalized(name)
                    guard !dll.isEmpty else { return }
                    add(dll, mode)
                    name = ""
                }
                .disabled(BuiltinLibraries.normalized(name).isEmpty)
            }
        }
        .task { libraries = BuiltinLibraries.names() }
    }
}
