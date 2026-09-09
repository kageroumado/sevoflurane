import SwiftUI

/// Settings › Games: every game with a file in the settings hierarchy, and
/// for the selected one the values it sets over the bottle's. A game gets a
/// file at its first launch, when its executables are recorded, so the list
/// is the games that have run. Writes take the path `sevo app config` takes.
struct GamesSettings: View {
    let shaders: ShaderStore
    let highlighted: String?
    @State private var games: [Entry] = []
    @State private var selected: Int?
    /// The selected game's own values, the form's model.
    @State private var values = ConfigValues.empty

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
            values = id.map(GameConfig.game) ?? .empty
        }
    }

    private var list: some View {
        List(games, selection: $selected) { entry in
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name).lineLimit(1)
                Text(entry.exes.isEmpty ? "no executable recorded yet" : entry.exes.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .listStyle(.sidebar)
        .frame(width: 220)
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
                windowsPicker(for: entry)
                UpscalerPicker(
                    shaders: shaders,
                    inherited: GameConfig.upscaler(bottle: SteamBottle.name).value,
                    selection: binding(\.upscaler, for: entry),
                )
                .highlightable(id: "games.upscaler", highlighted: highlighted)
                FinalFilterPicker(
                    inherited: GameConfig.filter(bottle: SteamBottle.name).value,
                    selection: binding(\.filter, for: entry),
                )
                mousePicker(for: entry)
            } header: {
                Text(entry.name)
            } footer: {
                Text("Inherit uses the value in Engine. Changes apply at the next game launch"
                    + (Engine.active.supportsEnvFiles ? "." : ", once Steam has restarted."))
            }
            .highlightable(id: "games.settings", highlighted: highlighted)
        }
        .formStyle(.grouped)
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
            Text("Make game windows resizable")
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
        values = selected.map(GameConfig.game) ?? .empty
    }
}
