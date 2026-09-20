import SwiftUI

/// Settings › Games: every game with a file in the settings hierarchy, and
/// for the selected one the values it sets over the bottle's. A game gets a
/// file at its first launch, when its executables are recorded, so the list
/// is the games that have run. Writes take the path `sevo app config` takes.
struct GamesSettings: View {
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @State private var games: [Entry] = []
    @State private var selected: Int?
    /// Opens on the first game, for the gallery, which has nobody to pick one.
    var selectsFirstGame = false
    /// The selected game's own values, the form's model.
    @State private var values = ConfigValues.empty
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
                    values: $values, recommendation: recommendation,
                )
            } else {
                GamesPlaceholder(hasGames: !games.isEmpty)
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { _, id in
            select(id)
        }
    }

    /// Loads a game's own values and what the fix table says about it.
    private func select(_ id: Int?) {
        values = id.map(GameConfig.game) ?? .empty
        recommendation = id.map {
            KnownFixes.recommended(for: $0, exes: values.exes ?? [])
        } ?? KnownFixes.Recommendation(fixes: [])
    }

    /// By name, then id, so two games without a name keep a stable order.
    private func reload() {
        games = GameConfig.games()
            .map { id, values in
                Entry(id: id, name: values.name ?? "App \(id)", exes: values.exes ?? [])
            }
            .sorted { a, b in
                let order = a.name.localizedStandardCompare(b.name)
                return order == .orderedSame ? a.id < b.id : order == .orderedAscending
            }
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
            Text(exes.isEmpty ? "no executable yet" : exes.joined(separator: ", "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

/// What the form's side shows while no game is selected.
private struct GamesPlaceholder: View {
    let hasGames: Bool

    var body: some View {
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

/// The selected game's form: its picture, its input, its performance
/// switches, then its DLL overrides.
private struct GameForm: View {
    let gameID: Int
    let name: String
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @Binding var values: ConfigValues
    let recommendation: KnownFixes.Recommendation

    var body: some View {
        let settings = GameSettings(gameID: gameID, values: $values, recommendation: recommendation)
        Form {
            GamePictureSection(name: name, shaders: shaders, highlighted: highlighted, settings: settings)
            GameInputSection(settings: settings)
            GamePerformanceSection(settings: settings)
            GameDLLOverridesSection(gameID: gameID, overrides: $values.dllOverrides)
        }
        .formStyle(.grouped)
    }
}

/// The selected game's values as the sections read and write them: a key's
/// binding writes the form's model, the game's file and the env files derived
/// from it, and a key's row carries what the fix table says about it.
private struct GameSettings {
    let gameID: Int
    @Binding var values: ConfigValues
    let recommendation: KnownFixes.Recommendation

    func binding<Value>(_ key: WritableKeyPath<ConfigValues, Value?>) -> Binding<Value?> {
        Binding(
            get: { values[keyPath: key] },
            set: { value in
                values[keyPath: key] = value
                GameConfig.update(game: gameID, bottle: SteamBottle.name, prefix: SteamBottle.root) {
                    $0[keyPath: key] = value
                }
            },
        )
    }

    func row<Value: Equatable>(
        _ key: WritableKeyPath<ConfigValues, Value?>, copy: SettingCopy? = nil, inherited: String? = nil,
        cost: SettingReach = .env, controlHasOwnLine: Bool = false,
        @ViewBuilder control: (Binding<Value?>) -> some View,
    ) -> some View {
        let selection = binding(key)
        let fix = recommendation.fix(setting: key)
        return GameSettingRow(
            copy: copy, inherited: inherited, cost: cost, controlHasOwnLine: controlHasOwnLine,
            selection: selection,
            recommended: fix?.values[keyPath: key], reason: fix?.reason,
        ) {
            control(selection)
        }
    }
}

/// What reaches the screen: the renderer, the window, the scaling, and the
/// two readouts drawn over the game.
private struct GamePictureSection: View {
    let name: String
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    let settings: GameSettings

    var body: some View {
        Section {
            // Automatic is the bottle's business — it consults CrossOver's own
            // per-game database — so a game names a layer or inherits.
            settings.row(
                \.renderer, inherited: BottleGraphics.currentSelection().renderer.label,
                cost: .renderer(settings.values.renderer),
            ) { selection in
                InheritingPicker(
                    title: "Renderer",
                    choices: Renderer.allCases.filter { $0 != .auto }, label: \.label,
                    selection: selection,
                )
            }
            settings.row(
                \.windows, copy: .windows,
                inherited: GameConfig.windows(bottle: SteamBottle.name).value.label,
            ) { selection in
                InheritingPicker(
                    title: SettingCopy.windows.title,
                    choices: WindowTreatment.allCases, label: \.label, selection: selection,
                )
            }
            settings.row(\.upscaler, controlHasOwnLine: true) { selection in
                UpscalerPicker(
                    shaders: shaders,
                    inherited: GameConfig.upscaler(bottle: SteamBottle.name).value,
                    selection: selection,
                )
                .highlightable(.gamesUpscaler, highlighted: highlighted)
            }
            settings.row(\.filter, controlHasOwnLine: true) { selection in
                FinalFilterPicker(
                    inherited: GameConfig.filter(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            settings.row(\.emulateModeset, copy: .modeset, cost: .nextLaunch) { selection in
                InheritingSwitch(
                    title: SettingCopy.modeset.title,
                    inherited: GameConfig.emulateModeset(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            settings.row(\.fps, copy: .fps) { selection in
                InheritingSwitch(
                    title: SettingCopy.fps.title,
                    inherited: GameConfig.fps(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            settings.row(\.hud, copy: .hud) { selection in
                InheritingSwitch(
                    title: SettingCopy.hud.title,
                    inherited: GameConfig.hud(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
        } header: {
            Text(name)
        } footer: {
            Text("Inherit takes the value from Settings › Engine. A change applies the next time the game starts.")
        }
        .highlightable(.gamesSettings, highlighted: highlighted)
    }
}

private struct GameInputSection: View {
    let settings: GameSettings

    var body: some View {
        Section("Mouse") {
            settings.row(
                \.mouse, copy: .mouse, inherited: GameConfig.mouse(bottle: SteamBottle.name).value.label,
            ) { selection in
                InheritingPicker(
                    title: "Movement",
                    choices: MouseCurve.allCases, label: \.label, selection: selection,
                )
            }
            settings.row(\.cursorConfine, copy: .cursorConfine) { selection in
                InheritingSwitch(
                    title: SettingCopy.cursorConfine.title,
                    inherited: GameConfig.cursorConfine(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
        }
    }
}

/// The switches that change how the game runs rather than how it looks, each
/// with its explanation behind an (i).
private struct GamePerformanceSection: View {
    let settings: GameSettings

    var body: some View {
        Section {
            settings.row(
                \.tuning, copy: .tuning, inherited: GameConfig.tuning(bottle: SteamBottle.name).value.label,
            ) { selection in
                InheritingPicker(
                    title: SettingCopy.tuning.title,
                    choices: PerformanceTuning.allCases, label: \.label, selection: selection,
                )
            }
            if settings.values.tuning == .custom {
                TuningParametersFields(parameters: parameters)
            }
            settings.row(\.unifiedMemory, copy: .unifiedMemory) { selection in
                InheritingSwitch(
                    title: SettingCopy.unifiedMemory.title,
                    inherited: GameConfig.unifiedMemory(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            settings.row(\.largeAddressAware, copy: .largeAddressAware) { selection in
                InheritingSwitch(
                    title: SettingCopy.largeAddressAware.title,
                    inherited: GameConfig.largeAddressAware(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            settings.row(\.avx, copy: .avx) { selection in
                InheritingSwitch(
                    title: SettingCopy.avx.title,
                    inherited: GameConfig.avx(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
        } header: {
            Text("Performance and compatibility")
        } footer: {
            Text("Leave these on Inherit unless a game needs one. The (i) says what each does and when to change it.")
        }
    }

    /// This game's custom parameters, starting from the experimental preset.
    private var parameters: Binding<TuningParameters> {
        let stored = settings.binding(\.tuningParameters)
        return Binding(
            get: { stored.wrappedValue ?? .experimental },
            set: { stored.wrappedValue = $0 },
        )
    }
}

/// One control with its (i), the line under it, what a change costs when
/// that is more than the next launch, and the chip the fix table earns when
/// it names a value this game does not have. Nothing applies itself; the
/// chip is the click.
private struct GameSettingRow<Value: Equatable, Control: View>: View {
    let copy: SettingCopy?
    /// What Inherit resolves to, for a picker whose closed face has no room
    /// to say it.
    let inherited: String?
    let cost: SettingReach
    /// The scaling pickers bring their own line and (i), which change with
    /// the choice.
    let controlHasOwnLine: Bool
    @Binding var selection: Value?
    /// The value the fix table names for this key, and the measurement behind it.
    let recommended: Value?
    let reason: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if controlHasOwnLine {
                control
            } else {
                HelpedRow(caption: caption, help: copy?.help) { control }
            }
            if cost == .clientRestart {
                Text("Steam restarts around this game's next launch, about 30 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let recommended, let reason, selection != recommended {
                RecommendedChip(reason: reason) { selection = recommended }
            }
        }
    }
}

private extension GameSettingRow {
    /// The line under the control: what Inherit stands for while the game
    /// inherits, then what the setting is.
    var caption: String {
        let what = copy?.caption ?? ""
        guard selection == nil, let inherited else { return what }
        return what.isEmpty ? "Engine's value: \(inherited)." : "Engine's value: \(inherited). \(what)"
    }
}

/// The mark a control wears when the fix table names a value this game does
/// not have, with the measurement behind it as the tooltip.
private struct RecommendedChip: View {
    let reason: String
    let use: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Recommended")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.tint.opacity(0.15), in: Capsule())
            Button("Use recommended", action: use)
                .buttonStyle(.link)
                .font(.caption)
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .help(reason)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Inheriting controls

/// A picker over a setting's cases whose first entry leaves the key to the
/// level above. The row's first line names what that level resolves to: a
/// choice's label is too long to share the closed picker with "Inherit".
private struct InheritingPicker<Choice: RawRepresentable & Hashable>: View
    where Choice.RawValue == String {
    let title: String
    let choices: [Choice]
    let label: KeyPath<Choice, String>
    @Binding var selection: Choice?

    var body: some View {
        Picker(selection: $selection.pickerTag) {
            Text("Inherit").tag("")
            ForEach(choices, id: \.self) { choice in
                Text(choice[keyPath: label]).tag(choice.rawValue)
            }
        } label: {
            Text(title)
        }
    }
}

/// A switch a game can leave to the level above.
private struct InheritingSwitch: View {
    let title: String
    let inherited: Bool
    @Binding var selection: Bool?

    var body: some View {
        Picker(selection: $selection.pickerTag) {
            Text("Inherit (\(inherited ? "On" : "Off"))").tag("")
            Text("On").tag(Bool.onTag)
            Text("Off").tag(Bool.offTag)
        } label: {
            Text(title)
        }
    }
}

private extension Optional where Wrapped: RawRepresentable, Wrapped.RawValue == String {
    /// This choice as a picker tag: its raw value, or the empty string for
    /// inherit.
    var pickerTag: String {
        get { self?.rawValue ?? "" }
        set { self = Wrapped(rawValue: newValue) }
    }
}

private extension Bool {
    static let onTag = "on"
    static let offTag = "off"
}

private extension Bool? {
    /// This switch as a picker tag: on, off, or the empty string for inherit.
    var pickerTag: String {
        get { map { $0 ? Bool.onTag : Bool.offTag } ?? "" }
        set { self = newValue.isEmpty ? nil : newValue == Bool.onTag }
    }
}

// MARK: - DLL overrides

/// The load order this game gives named DLLs, over the bottle's own
/// overrides. Written under `AppDefaults\<exe>\DllOverrides`, so a game
/// can take a native runtime the rest of the bottle does not.
private struct GameDLLOverridesSection: View {
    let gameID: Int
    @Binding var overrides: [String: String]?

    var body: some View {
        let table = (overrides ?? [:]).sorted { $0.key < $1.key }
        Section {
            ForEach(table, id: \.key) { dll, mode in
                DLLOverrideRow(dll: dll, mode: mode) { set(dll: dll, mode: $0) }
            }
            AddDLLOverrideRow(gameID: gameID) { dll, mode in set(dll: dll, mode: mode) }
        } header: {
            HStack(spacing: 6) {
                Text("DLL overrides")
                SettingHelpButton(help: SettingCopy.dllOverrides)
            }
        } footer: {
            Text("For this game alone, from its next launch. winecfg shows the same values; "
                + "Settings › Engine holds the bottle's.")
        }
    }

    /// Gives `dll` a load order, or with `nil` takes its override away.
    private func set(dll: String, mode: String?) {
        var table = overrides ?? [:]
        table[dll] = mode
        let updated = table.isEmpty ? nil : table
        overrides = updated
        GameConfig.update(game: gameID, bottle: SteamBottle.name, prefix: SteamBottle.root) {
            $0.dllOverrides = updated
        }
    }
}

/// Wine's load orders in the spelling the registry holds, so the picker
/// and `sevo app config <id> dll` name the same values.
private let dllOverrideModes: [(mode: String, label: String)] = [
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
            Picker("", selection: Binding(get: { mode }, set: { set($0) })) {
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
            .accessibilityLabel("Remove the override for \(dll)")
        }
    }
}

/// The row that names a DLL and a load order and adds the pair. A change of
/// game clears the name.
private struct AddDLLOverrideRow: View {
    let gameID: Int
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
        .onChange(of: gameID) { name = "" }
        .task { libraries = BuiltinLibraries.names() }
    }
}
