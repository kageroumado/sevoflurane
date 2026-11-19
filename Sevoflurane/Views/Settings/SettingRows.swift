import Propofol
import SwiftUI

/// The catalog's groups as form sections for the store's level.
struct SettingSections: View {
    let store: SettingsStore
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    /// The game the sections belong to, over the first of them.
    var heading: String?
    /// What the fix table says about that game.
    var recommendation = KnownFixes.Recommendation(fixes: [])

    var body: some View {
        let level = store.level
        let groups = store.groups
        ForEach(groups, id: \.group) { group, settings in
            Section {
                ForEach(settings) { setting in
                    SettingRow(
                        setting: setting, store: store, shaders: shaders,
                        recommended: setting.recommended(recommendation),
                        fixed: fixMark(for: setting),
                    )
                    .highlightable(setting.id.anchor(at: level), highlighted: highlighted)
                }
            } header: {
                SettingGroupHeader(title: group.title, heading: group == groups.first?.group ? heading : nil)
            } footer: {
                if let footer = Self.footer(of: group, at: level) { Text(footer) }
            }
        }
    }

    /// The fix list's mark for a row whose value it set and nobody changed since.
    private func fixMark(for setting: Setting) -> SettingRow.FixMark? {
        let key = setting.id.rawValue
        guard let appliedFixes = store.appliedFixes, appliedFixes.sets(key, in: store.values) else { return nil }
        return SettingRow.FixMark(reason: appliedFixes.reasons) { store.undoFixes([key]) }
    }

    private static func footer(of group: SettingGroup, at level: SettingLevel) -> LocalizedStringResource? {
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

/// One setting: its control, caption, restart cost, and the fix table's
/// recommendation or the fix list's mark with its undo.
struct SettingRow: View {
    let setting: Setting
    let store: SettingsStore
    let shaders: ShaderStore
    let recommended: (value: SettingValue, reason: String)?
    var fixed: FixMark?

    /// The fix list set this row's value: why, and what puts it back.
    struct FixMark {
        let reason: String
        let undo: () -> Void
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if setting.control == .upscaler {
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
            if let fixed {
                FixListMark(reason: fixed.reason, undo: fixed.undo)
            } else if let recommended, store.own(setting) != recommended.value {
                RecommendedChip(reason: recommended.reason) {
                    store.send(.set(setting.id, recommended.value))
                }
            }
        }
    }

    /// The line under the control, led by the engine's value while inheriting.
    private var caption: String {
        let what = setting.detail?(store.effective(setting)) ?? setting.copy.caption
        guard store.level == .game, store.own(setting) == nil, setting.control != .toggle, setting.inherits
        else { return what }
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

/// The control the catalog names, with Inherit at the game level.
private struct SettingControlView: View {
    let setting: Setting
    let store: SettingsStore

    private static let inheritTag = ""
    private static let onTag = "on"
    private static let offTag = "off"

    var body: some View {
        switch (setting.control, store.level) {
        case (.toggle, .bottle):
            // Inside the row's stack the switch loses the form's title for VoiceOver.
            Toggle(setting.title, isOn: store.flagBinding(setting))
                .accessibilityLabel(setting.title)
        case (.toggle, .game):
            Picker(setting.title, selection: tag) {
                Text("Inherit (\(setting.label(of: store.inherited(setting))))").tag(Self.inheritTag)
                Text("On").tag(Self.onTag)
                Text("Off").tag(Self.offTag)
            }
        case let (.choices(choices), level), let (.tuning(choices), level):
            let inherits = level == .game && setting.inherits
            Picker(setting.title, selection: inherits ? tag : store.choiceBinding(setting)) {
                // Plain "Inherit": the caption says what it stands for.
                if inherits { Text("Inherit").tag(Self.inheritTag) }
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

/// The fix table's recommendation, with its reason as the tooltip.
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
                .accessibilityHint(InterfaceCopy.localized(reason))
            // The button's hint carries the tooltip to VoiceOver.
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
        .help(InterfaceCopy.localized(reason))
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Marks a value the fix list set at first launch, with its reason and undo.
struct FixListMark: View {
    let reason: String
    let undo: () -> Void

    var body: some View {
        HStack(spacing: Theme.Space.xs) {
            Text("Set by the fix list")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button("Undo", action: undo)
                .buttonStyle(.link)
                .font(.caption)
                .accessibilityHint(reason)
        }
        .help(reason)
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
