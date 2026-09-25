import Propofol
import SwiftUI

/// The catalog's groups as form sections, for whichever level the store
/// edits. The pane that hosts them names no setting.
struct SettingSections: View {
    let store: SettingsStore
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    /// The game the sections belong to, over the first of them.
    var heading: String?
    /// What the fix table says about that game.
    var recommendation = KnownFixes.Recommendation(fixes: [])

    var body: some View {
        ForEach(SettingGroup.allCases, id: \.self) { group in
            Section {
                ForEach(SettingCatalog.settings(in: group, at: store.level)) { setting in
                    SettingRow(
                        setting: setting, store: store, shaders: shaders,
                        recommended: setting.recommended(recommendation),
                    )
                    .highlightable(setting.id.anchor(at: store.level), highlighted: highlighted)
                }
            } header: {
                SettingGroupHeader(title: group.title, heading: group == .picture ? heading : nil)
            } footer: {
                if let footer = Self.footer(of: group, at: store.level) { Text(footer) }
            }
        }
    }

    private static func footer(of group: SettingGroup, at level: SettingLevel) -> String? {
        switch (group, level) {
        case (.picture, .game):
            "Inherit takes the value from Settings › Engine. A change applies the next time the game starts."
        case (.performance, .game):
            "Leave these on Inherit unless a game needs one. The (i) says what each does and when to change it."
        case (.performance, .bottle):
            Engine.active.supportsEnvFiles
                ? "Defaults for every game on Dormison. Settings › Games changes one game. A change applies at a game's next launch."
                : "Defaults for every game on Dormison. Settings › Games changes one game. Restart Steam to apply a change."
        default: nil
        }
    }
}

private struct SettingGroupHeader: View {
    let title: String
    let heading: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            if let heading {
                Text(heading).font(.title3.weight(.medium))
            }
            Text(title)
        }
    }
}

/// One setting: its control with an (i), the line under it, what a change
/// costs when that is more than the next launch, and the chip the fix table
/// earns when it names a value this game does not have. Nothing applies
/// itself; the chip is the click.
struct SettingRow: View {
    let setting: Setting
    let store: SettingsStore
    let shaders: ShaderStore
    let recommended: (value: SettingValue, reason: String)?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if setting.control == .upscaler {
                // The shader store names the choices, fetches the ones that
                // are downloads, and writes the line under the picker.
                UpscalerPicker(
                    shaders: shaders,
                    inherited: store.level == .game ? store.inherited(setting).choice : nil,
                    selection: upscalerSelection,
                )
            } else {
                HelpedRow(caption: caption, help: setting.copy.help) {
                    SettingControlView(setting: setting, store: store)
                }
            }
            if case .tuning = setting.control, store.effective(setting) == .choice(PerformanceTuning.custom.rawValue),
               store.own(setting) != nil || store.level == .bottle {
                TuningParametersFields(parameters: store.tuningParametersBinding)
            }
            if setting.reach(store.own(setting)) == .clientRestart {
                Text("Steam restarts at the next launch, which takes about 30 seconds.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let recommended, store.own(setting) != recommended.value {
                RecommendedChip(reason: recommended.reason) {
                    store.send(.set(setting.id, recommended.value))
                }
            }
        }
    }

    /// The line under the control: what Inherit stands for while the level
    /// inherits, then what the setting — or the value in force — is.
    private var caption: String {
        let what = setting.detail?(store.effective(setting)) ?? setting.copy.caption
        guard store.level == .game, store.own(setting) == nil, setting.control != .toggle else { return what }
        let inherited = String(localized: "Engine's value: \(setting.label(of: store.inherited(setting))).")
        return what.isEmpty ? inherited : "\(inherited) \(what)"
    }

    /// The picker hands back `nil` for Inherit, which a bottle cannot choose.
    private var upscalerSelection: Binding<String?> {
        Binding(
            get: { store.level == .game ? store.own(setting)?.choice : store.effective(setting).choice },
            set: { value in
                guard value != nil || store.level == .game else { return }
                store.send(.set(setting.id, value.map(SettingValue.choice)))
            },
        )
    }
}

/// The control itself, by what the catalog says it is and whether its level
/// can inherit.
private struct SettingControlView: View {
    let setting: Setting
    let store: SettingsStore

    private static let inheritTag = ""
    private static let onTag = "on"
    private static let offTag = "off"

    var body: some View {
        switch (setting.control, store.level) {
        case (.toggle, .bottle):
            // Said aloud: inside a row's stack the switch loses the title the
            // form would have read for it.
            Toggle(setting.title, isOn: store.flagBinding(setting))
                .accessibilityLabel(setting.title)
        case (.toggle, .game):
            Picker(setting.title, selection: tag) {
                Text("Inherit (\(setting.label(of: store.inherited(setting))))").tag(Self.inheritTag)
                Text("On").tag(Self.onTag)
                Text("Off").tag(Self.offTag)
            }
        case let (.choices(choices), level), let (.tuning(choices), level):
            Picker(setting.title, selection: level == .game ? tag : store.choiceBinding(setting)) {
                // A choice's label is too long to share the closed picker
                // with "Inherit"; the row's line says what it stands for.
                if level == .game { Text("Inherit").tag(Self.inheritTag) }
                ForEach(choices) { choice in
                    Text(choice.label).tag(choice.value)
                }
            }
        case (.upscaler, _):
            EmptyView()
        }
    }

    /// The level's own value as a picker tag, the empty one for Inherit.
    private var tag: Binding<String> {
        Binding(
            get: {
                switch store.own(setting) {
                case nil: Self.inheritTag
                case let .flag(on): on ? Self.onTag : Self.offTag
                case let .choice(raw): raw
                }
            },
            set: { tag in
                let value: SettingValue? = switch (tag, setting.control) {
                case (Self.inheritTag, _): nil
                case (_, .toggle): .flag(tag == Self.onTag)
                default: .choice(tag)
                }
                store.send(.set(setting.id, value))
            },
        )
    }
}

/// The mark a control wears when the fix table names a value this game does
/// not have, with the measurement behind it as the tooltip.
private struct RecommendedChip: View {
    let reason: String
    let use: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.sm) {
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
        .help(InterfaceCopy.localized(reason))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SettingID {
    /// The row search flashes for this setting, where search knows one.
    func anchor(at level: SettingLevel) -> SettingsAnchor? {
        switch (self, level) {
        case (.windows, .bottle): .engineWindows
        case (.upscaler, .bottle): .engineUpscaler
        case (.filter, .bottle): .engineFilter
        case (.mouse, .bottle): .engineMouse
        case (.upscaler, .game): .gamesUpscaler
        default: nil
        }
    }
}
