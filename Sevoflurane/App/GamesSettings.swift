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

    var body: some View {
        List(games, selection: $selected) { entry in
            GameListRow(name: entry.name, exes: entry.exes)
        }
        .listStyle(.sidebar)
        .frame(width: 200)
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

/// The selected game's form: its settings, then its DLL overrides.
private struct GameForm: View {
    let gameID: Int
    let name: String
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @Binding var values: ConfigValues
    let recommendation: KnownFixes.Recommendation

    var body: some View {
        Form {
            GameSettingsSection(
                gameID: gameID, name: name, shaders: shaders, highlighted: highlighted,
                values: $values, recommendation: recommendation,
            )
            GameDLLOverridesSection(gameID: gameID, overrides: $values.dllOverrides)
        }
        .formStyle(.grouped)
    }
}

/// Every key a game can set over the bottle's, one ``GameSettingRow`` each.
private struct GameSettingsSection: View {
    let gameID: Int
    let name: String
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @Binding var values: ConfigValues
    let recommendation: KnownFixes.Recommendation

    var body: some View {
        Section {
            // Automatic is the bottle's business — it consults CrossOver's own
            // per-game database — so a game names a layer or inherits.
            row(\.renderer, cost: .renderer(values.renderer)) { selection in
                InheritingPicker(
                    title: "Renderer",
                    inherited: BottleGraphics.currentSelection().renderer.label,
                    choices: Renderer.allCases.filter { $0 != .auto }, label: \.label,
                    selection: selection,
                )
            }
            row(\.windows, cost: .env) { selection in
                InheritingPicker(
                    title: "Resizable windows",
                    inherited: GameConfig.windows(bottle: SteamBottle.name).value.label,
                    choices: WindowTreatment.allCases, label: \.label, selection: selection,
                )
            }
            row(\.upscaler, cost: .env) { selection in
                UpscalerPicker(
                    shaders: shaders,
                    inherited: GameConfig.upscaler(bottle: SteamBottle.name).value,
                    selection: selection,
                )
                .highlightable(.gamesUpscaler, highlighted: highlighted)
            }
            row(\.filter, cost: .env) { selection in
                FinalFilterPicker(
                    inherited: GameConfig.filter(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.mouse, cost: .env) { selection in
                InheritingPicker(
                    title: "Mouse",
                    inherited: GameConfig.mouse(bottle: SteamBottle.name).value.label,
                    choices: MouseCurve.allCases, label: \.label, selection: selection,
                )
            }
            row(\.emulateModeset, cost: .nextLaunch) { selection in
                InheritingSwitch(
                    title: "Fake display-mode changes",
                    inherited: GameConfig.emulateModeset(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.fps, cost: .env) { selection in
                InheritingSwitch(
                    title: "Frame rate counter",
                    inherited: GameConfig.fps(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.hud, cost: .env) { selection in
                InheritingSwitch(
                    title: "Performance HUD",
                    inherited: GameConfig.hud(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.cursorConfine, cost: .env) { selection in
                InheritingSwitch(
                    title: "Keep the pointer in the window",
                    inherited: GameConfig.cursorConfine(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.avx, cost: .env) { selection in
                InheritingSwitch(
                    title: "Report AVX to the game",
                    inherited: GameConfig.avx(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.tuning, cost: .env) { selection in
                InheritingPicker(
                    title: "Performance tuning",
                    inherited: GameConfig.tuning(bottle: SteamBottle.name).value.label,
                    choices: PerformanceTuning.allCases, label: \.label, selection: selection,
                )
            }
            row(\.unifiedMemory, cost: .env) { selection in
                InheritingSwitch(
                    title: "Unified memory",
                    inherited: GameConfig.unifiedMemory(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
            row(\.largeAddressAware, cost: .env) { selection in
                InheritingSwitch(
                    title: "Full address space (32-bit games)",
                    inherited: GameConfig.largeAddressAware(bottle: SteamBottle.name).value,
                    selection: selection,
                )
            }
        } header: {
            Text(name)
        } footer: {
            Text("Inherit uses the value from Engine. Each setting says which "
                + "level it comes from and what a change costs.")
        }
        .highlightable(.gamesSettings, highlighted: highlighted)
    }

    /// The row for one key: its control on the key's binding, and what the
    /// fix table says about the key.
    private func row<Value: Equatable>(
        _ key: WritableKeyPath<ConfigValues, Value?>, cost: SettingReach,
        @ViewBuilder control: (Binding<Value?>) -> some View,
    ) -> some View {
        let selection = binding(key)
        let fix = recommendation.fix(setting: key)
        return GameSettingRow(
            key: key, cost: cost, selection: selection,
            recommended: fix?.values[keyPath: key], reason: fix?.reason,
        ) {
            control(selection)
        }
    }

    /// One key of the selected game's values: reads the form's model, writes
    /// the game's file and the env files derived from it.
    private func binding<Value>(_ key: WritableKeyPath<ConfigValues, Value?>) -> Binding<Value?> {
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
}

/// One control, the two badges saying where its value comes from and what
/// a change costs, and the chip the fix table earns when it names a value
/// this game does not have. Nothing applies itself; the chip is the click.
private struct GameSettingRow<Value: Equatable, Control: View>: View {
    let key: KeyPath<ConfigValues, Value?>
    let cost: SettingReach
    @Binding var selection: Value?
    /// The value the fix table names for this key, and the measurement behind it.
    let recommended: Value?
    let reason: String?
    @ViewBuilder let control: Control

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            control
            HStack(spacing: 6) {
                SettingBadge(text: level, help: "Where this setting's value comes from.")
                SettingBadge(text: cost.label, help: cost.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let recommended, let reason, selection != recommended {
                RecommendedChip(reason: reason) { selection = recommended }
            }
        }
    }

    /// Which level the resolved value comes from, read the way the resolver
    /// reads it.
    private var level: String {
        if selection != nil { return "This game" }
        if GameConfig.bottle(SteamBottle.name)[keyPath: key] != nil { return "Engine" }
        if GameConfig.global()[keyPath: key] != nil { return "All games" }
        return "Default"
    }
}

/// One of the two marks under a control: quiet, small, and explained by
/// its tooltip.
private struct SettingBadge: View {
    let text: String
    let help: String

    var body: some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(.quaternary.opacity(0.5), in: Capsule())
            .help(help)
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
/// level above, naming what that level resolves to.
private struct InheritingPicker<Choice: RawRepresentable & Hashable>: View
    where Choice.RawValue == String {
    let title: String
    /// The label of the value the level above resolves to.
    let inherited: String
    let choices: [Choice]
    let label: KeyPath<Choice, String>
    @Binding var selection: Choice?

    var body: some View {
        Picker(selection: $selection.pickerTag) {
            Text("Inherit (\(inherited))").tag("")
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
            Text("DLL overrides")
        } footer: {
            Text("Applies to this game alone, at its next launch. "
                + "Settings › Engine holds the bottle's own overrides.")
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
            Text(dll)
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

    var body: some View {
        HStack {
            TextField("DLL name", text: $name, prompt: Text("d3dcompiler_47"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Picker("", selection: $mode) {
                ForEach(dllOverrideModes, id: \.mode) { choice in
                    Text(choice.label).tag(choice.mode)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button("Add") {
                let dll = name
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".dll", with: "")
                    .lowercased()
                guard !dll.isEmpty else { return }
                add(dll, mode)
                name = ""
            }
            .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .onChange(of: gameID) { name = "" }
    }
}
