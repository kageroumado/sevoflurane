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
    @State private var newOverrideDLL = ""
    @State private var newOverrideMode = "n,b"
    /// What the fix table says about the selected game.
    @State private var recommendation = KnownFixes.Recommendation(fixes: [])

    struct Entry: Identifiable, Equatable {
        let id: Int
        let name: String
        let exes: [String]
    }

    var body: some View {
        HStack(spacing: 0) {
            list
            Divider()
            if let selected, let entry = games.first(where: { $0.id == selected }) {
                form(for: entry)
            } else {
                placeholder
            }
        }
        .onAppear(perform: reload)
        .onChange(of: selected) { _, id in
            select(id)
        }
    }

    private var list: some View {
        List(games, selection: $selected) { entry in
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(entry.exes.isEmpty ? "no executable yet" : entry.exes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 200)
    }

    @ViewBuilder private var placeholder: some View {
        if games.isEmpty {
            ContentUnavailableView(
                "No games yet", systemImage: "gamecontroller",
                description: Text("Games appear here after their first launch."),
            )
        } else {
            ContentUnavailableView(
                "Choose a game", systemImage: "gamecontroller",
                description: Text("Customize its window, upscaler, and mouse settings."),
            )
        }
    }

    private func form(for entry: Entry) -> some View {
        Form {
            Section {
                settingRow(\.renderer, cost: .renderer(values.renderer), for: entry) {
                    rendererPicker(for: entry)
                }
                settingRow(\.windows, cost: .env, for: entry) { windowsPicker(for: entry) }
                settingRow(\.upscaler, cost: .env, for: entry) {
                    UpscalerPicker(
                        shaders: shaders,
                        inherited: GameConfig.upscaler(bottle: SteamBottle.name).value,
                        selection: binding(\.upscaler, for: entry),
                    )
                    .highlightable(.gamesUpscaler, highlighted: highlighted)
                }
                settingRow(\.filter, cost: .env, for: entry) {
                    FinalFilterPicker(
                        inherited: GameConfig.filter(bottle: SteamBottle.name).value,
                        selection: binding(\.filter, for: entry),
                    )
                }
                settingRow(\.mouse, cost: .env, for: entry) { mousePicker(for: entry) }
                settingRow(\.emulateModeset, cost: .nextLaunch, for: entry) {
                    inheritableSwitch(
                        "Fake display-mode changes", key: \.emulateModeset,
                        inherited: GameConfig.emulateModeset(bottle: SteamBottle.name).value,
                        for: entry,
                    )
                }
                settingRow(\.hud, cost: .env, for: entry) {
                    inheritableSwitch(
                        "Performance HUD", key: \.hud,
                        inherited: GameConfig.hud(bottle: SteamBottle.name).value, for: entry,
                    )
                }
                settingRow(\.cursorConfine, cost: .env, for: entry) {
                    inheritableSwitch(
                        "Keep the pointer in the window", key: \.cursorConfine,
                        inherited: GameConfig.cursorConfine(bottle: SteamBottle.name).value,
                        for: entry,
                    )
                }
                settingRow(\.avx, cost: .env, for: entry) {
                    inheritableSwitch(
                        "Report AVX to the game", key: \.avx,
                        inherited: GameConfig.avx(bottle: SteamBottle.name).value, for: entry,
                    )
                }
                settingRow(\.tuning, cost: .env, for: entry) { tuningPicker(for: entry) }
                settingRow(\.unifiedMemory, cost: .env, for: entry) {
                    inheritableSwitch(
                        "Unified memory", key: \.unifiedMemory,
                        inherited: GameConfig.unifiedMemory(bottle: SteamBottle.name).value,
                        for: entry,
                    )
                }
                settingRow(\.largeAddressAware, cost: .recorded, for: entry) {
                    inheritableSwitch(
                        "Full address space (32-bit games)", key: \.largeAddressAware,
                        inherited: GameConfig.largeAddressAware(bottle: SteamBottle.name).value,
                        for: entry,
                    )
                }
            } header: {
                Text(entry.name)
            } footer: {
                Text("Inherit uses the value from Engine. Each setting says which "
                    + "level it comes from and what a change costs.")
            }
            .highlightable(.gamesSettings, highlighted: highlighted)
            dllOverridesSection(for: entry)
        }
        .formStyle(.grouped)
    }

    /// Loads a game's own values and what the fix table says about it.
    private func select(_ id: Int?) {
        values = id.map(GameConfig.game) ?? .empty
        recommendation = id.map {
            KnownFixes.recommended(for: $0, exes: values.exes ?? [])
        } ?? KnownFixes.Recommendation(fixes: [])
        newOverrideDLL = ""
    }

    /// Which level the resolved value comes from, read the way the resolver
    /// reads it.
    private func level(_ key: KeyPath<ConfigValues, (some Any)?>) -> String {
        if values[keyPath: key] != nil { return "This game" }
        if GameConfig.bottle(SteamBottle.name)[keyPath: key] != nil { return "Engine" }
        if GameConfig.global()[keyPath: key] != nil { return "All games" }
        return "Default"
    }

    /// One control, the two badges saying where its value comes from and what
    /// a change costs, and the chip the fix table earns when it names a value
    /// this game does not have. Nothing applies itself; the chip is the click.
    @ViewBuilder
    private func settingRow(
        _ key: WritableKeyPath<ConfigValues, (some Equatable)?>, cost: SettingReach, for entry: Entry,
        @ViewBuilder control: () -> some View,
    ) -> some View {
        let fix = recommendation.fix(setting: key)
        let wanted = fix?.values[keyPath: key]
        VStack(alignment: .leading, spacing: 4) {
            control()
            HStack(spacing: 6) {
                SettingBadge(text: level(key), help: "Where this setting's value comes from.")
                SettingBadge(text: cost.label, help: cost.detail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if let fix, let wanted, values[keyPath: key] != wanted {
                RecommendedChip(reason: fix.reason) {
                    values[keyPath: key] = wanted
                    GameConfig.update(
                        game: entry.id, bottle: SteamBottle.name, prefix: SteamBottle.root,
                    ) {
                        $0[keyPath: key] = wanted
                    }
                }
            }
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

    /// A switch a game can leave to the level above.
    private func inheritableSwitch(
        _ title: String, key: WritableKeyPath<ConfigValues, Bool?>,
        inherited: Bool, for entry: Entry,
    ) -> some View {
        let selection = binding(key, for: entry)
        return Picker(selection: Binding(
            get: { selection.wrappedValue.map { $0 ? Self.on : Self.off } ?? "" },
            set: { selection.wrappedValue = $0.isEmpty ? nil : $0 == Self.on },
        )) {
            Text("Inherit (\(inherited ? "On" : "Off"))").tag("")
            Text("On").tag(Self.on)
            Text("Off").tag(Self.off)
        } label: {
            Text(title)
        }
    }

    private static let on = "on"
    private static let off = "off"

    /// The load order this game gives named DLLs, over the bottle's own
    /// overrides. Written under `AppDefaults\<exe>\DllOverrides`, so a game
    /// can take a native runtime the rest of the bottle does not.
    private func dllOverridesSection(for entry: Entry) -> some View {
        let table = (values.dllOverrides ?? [:]).sorted { $0.key < $1.key }
        return Section {
            ForEach(table, id: \.key) { dll, mode in
                overrideRow(dll: dll, mode: mode, for: entry)
            }
            addOverrideRow(for: entry)
        } header: {
            Text("DLL overrides")
        } footer: {
            Text("Applies to this game alone, at its next launch. "
                + "Settings › Engine holds the bottle's own overrides.")
        }
    }

    private func overrideRow(dll: String, mode: String, for entry: Entry) -> some View {
        HStack {
            Text(dll)
            Spacer()
            Picker("", selection: Binding(
                get: { mode },
                set: { setOverride(dll: dll, mode: $0, for: entry) },
            )) {
                ForEach(Self.overrideModes, id: \.mode) { choice in
                    Text(choice.label).tag(choice.mode)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button {
                setOverride(dll: dll, mode: nil, for: entry)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Remove the override for \(dll)")
        }
    }

    private func addOverrideRow(for entry: Entry) -> some View {
        HStack {
            TextField("DLL name", text: $newOverrideDLL, prompt: Text("d3dcompiler_47"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            Picker("", selection: $newOverrideMode) {
                ForEach(Self.overrideModes, id: \.mode) { choice in
                    Text(choice.label).tag(choice.mode)
                }
            }
            .labelsHidden()
            .frame(width: 180)
            Button("Add") {
                let dll = newOverrideDLL
                    .trimmingCharacters(in: .whitespaces)
                    .replacingOccurrences(of: ".dll", with: "")
                    .lowercased()
                guard !dll.isEmpty else { return }
                setOverride(dll: dll, mode: newOverrideMode, for: entry)
                newOverrideDLL = ""
            }
            .disabled(newOverrideDLL.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    /// Wine's load orders in the spelling the registry holds, so the picker
    /// and `sevo app config <id> dll` name the same values.
    private static let overrideModes: [(mode: String, label: String)] = [
        ("n,b", "Native, then built-in"),
        ("b,n", "Built-in, then native"),
        ("n", "Native only"),
        ("b", "Built-in only"),
        ("", "Disabled"),
    ]

    private func setOverride(dll: String, mode: String?, for entry: Entry) {
        var table = values.dllOverrides ?? [:]
        table[dll] = mode
        let updated = table.isEmpty ? nil : table
        values.dllOverrides = updated
        GameConfig.update(game: entry.id, bottle: SteamBottle.name, prefix: SteamBottle.root) {
            $0.dllOverrides = updated
        }
    }

    /// The translation layer this game renders through. Automatic is the
    /// bottle's business — it consults CrossOver's own per-game database — so
    /// a game names a layer or inherits.
    private func rendererPicker(for entry: Entry) -> some View {
        let inherited = BottleGraphics.currentSelection().renderer
        let selection = binding(\.renderer, for: entry)
        return Picker(selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { selection.wrappedValue = Renderer(rawValue: $0) },
        )) {
            Text("Inherit (\(inherited.label))").tag("")
            ForEach(Renderer.allCases.filter { $0 != .auto }, id: \.self) { renderer in
                Text(renderer.label).tag(renderer.rawValue)
            }
        } label: {
            Text("Renderer")
        }
    }

    private func windowsPicker(for entry: Entry) -> some View {
        let inherited = GameConfig.windows(bottle: SteamBottle.name).value
        let selection = binding(\.windows, for: entry)
        return Picker(selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { selection.wrappedValue = WindowTreatment(rawValue: $0) },
        )) {
            Text("Inherit (\(inherited.label))").tag("")
            ForEach(WindowTreatment.allCases, id: \.self) { treatment in
                Text(treatment.label).tag(treatment.rawValue)
            }
        } label: {
            Text("Resizable windows")
        }
    }

    private func mousePicker(for entry: Entry) -> some View {
        let inherited = GameConfig.mouse(bottle: SteamBottle.name).value
        let selection = binding(\.mouse, for: entry)
        return Picker(selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { selection.wrappedValue = MouseCurve(rawValue: $0) },
        )) {
            Text("Inherit (\(inherited.label))").tag("")
            ForEach(MouseCurve.allCases, id: \.self) { curve in
                Text(curve.label).tag(curve.rawValue)
            }
        } label: {
            Text("Mouse")
        }
    }

    private func tuningPicker(for entry: Entry) -> some View {
        let inherited = GameConfig.tuning(bottle: SteamBottle.name).value
        let selection = binding(\.tuning, for: entry)
        return Picker(selection: Binding(
            get: { selection.wrappedValue?.rawValue ?? "" },
            set: { selection.wrappedValue = PerformanceTuning(rawValue: $0) },
        )) {
            Text("Inherit (\(inherited.label))").tag("")
            ForEach(PerformanceTuning.allCases, id: \.self) { tuning in
                Text(tuning.label).tag(tuning.rawValue)
            }
        } label: {
            Text("Performance tuning")
        }
    }

    /// One key of the selected game's values: reads the form's model, writes
    /// the game's file and the env files derived from it.
    private func binding<Value>(
        _ key: WritableKeyPath<ConfigValues, Value?>, for entry: Entry,
    ) -> Binding<Value?> {
        Binding(
            get: { values[keyPath: key] },
            set: { value in
                values[keyPath: key] = value
                GameConfig.update(game: entry.id, bottle: SteamBottle.name, prefix: SteamBottle.root) {
                    $0[keyPath: key] = value
                }
            },
        )
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
