import SwiftUI

/// The variables a level sets by name (``UserEnvironment``). Settings › Engine
/// shows the bottle's, Settings › Games a game's.
struct EnvironmentSection: View {
    let store: SettingsStore

    private static let rules = KeyValueEditor.Rules(
        problem: { UserEnvironment.problem(name: $0, value: $1)?.message },
        remark: { name in
            UserEnvironment.managingSetting(of: name).map {
                String(localized: "Takes the place of the \($0) setting.")
            }
        },
        removeLabel: { String(localized: "Remove \($0)") },
    )

    var body: some View {
        SettingsSection(
            title: "Environment", help: SettingCopy.environment,
            footer: store.level == .game ? "For this game alone." : "For every game; a game can add its own.",
            reach: .env,
        ) {
            KeyValueEditor(
                entries: (store.values.environment ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { KeyValueEditor.Entry(key: $0.key, value: $0.value) },
                values: .text(prompt: "1"),
                separator: "=",
                keyPrompt: "DXVK_HUD",
                rules: Self.rules,
            ) { name, value in
                store.send(.setEnvironment(name: name, value: value))
            }
        }
    }
}

/// A game's DLL load orders over the bottle's, written under
/// `AppDefaults\<exe>\DllOverrides`.
struct GameDLLOverridesSection: View {
    let store: SettingsStore
    @State private var libraries: [String] = []

    var body: some View {
        SettingsSection(
            title: "DLL overrides", anchor: .engineOverrides, help: SettingCopy.dllOverrides,
            footer: "For this game alone; winecfg shows the same values.", reach: .nextLaunch,
        ) {
            KeyValueEditor(
                entries: (store.values.dllOverrides ?? [:])
                    .sorted { $0.key < $1.key }
                    .map { KeyValueEditor.Entry(key: $0.key, value: $0.value) },
                values: .choices(DLLOverrideEditing.gameOrders, initial: "n,b"),
                keyPrompt: DLLOverrideEditing.prompt,
                completions: libraries,
                rules: DLLOverrideEditing.rules,
            ) { library, order in
                store.send(.setDLLOverride(library: library, order: order))
            }
        }
        .task { libraries = BuiltinLibraries.names() }
    }
}

/// The bottle's DLL load orders, for every program in it.
struct BottleDLLOverridesSection: View {
    let compatibility: CompatibilityStore
    let highlighted: SettingsAnchor?
    @State private var libraries: [String] = []

    var body: some View {
        SettingsSection(
            title: "DLL overrides", anchor: .engineOverrides, help: SettingCopy.dllOverrides,
            footer: "For every program in this bottle; winecfg shows the same values.", reach: .nextLaunch,
        ) {
            KeyValueEditor(
                entries: compatibility.overrides.map { KeyValueEditor.Entry(key: $0.dll, value: $0.mode) },
                values: .choices(DLLOverrideEditing.bottleOrders, initial: BottleDependencies.overrideModes[0]),
                keyPrompt: DLLOverrideEditing.prompt,
                completions: libraries,
                rules: DLLOverrideEditing.rules,
            ) { library, order in
                if let order {
                    compatibility.setOverride(dll: library, mode: order)
                } else if let override = compatibility.overrides.first(where: { $0.dll == library }) {
                    compatibility.removeOverride(override)
                }
            }
            if let error = compatibility.overrideError {
                SettingsNotice(.failure, error)
            }
        }
        .highlightableSection(.engineOverrides, highlighted: highlighted)
        .task { libraries = BuiltinLibraries.names() }
    }
}
