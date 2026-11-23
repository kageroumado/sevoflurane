import SwiftUI

/// The catalog's groups as sections for the store's level.
struct SettingSections: View {
    let store: SettingsStore
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    /// The groups this pane shows; every group of the level when `nil`.
    var groups: Set<SettingGroup>?
    /// The game the sections belong to, over the first of them.
    var heading: String?
    /// What the fix table says about that game.
    var recommendation = KnownFixes.Recommendation(fixes: [])

    var body: some View {
        let level = store.level
        let shown = store.groups.filter { groups?.contains($0.group) ?? true }
        ForEach(shown, id: \.group) { group, settings in
            SettingsSection(
                title: "\(group.title)",
                heading: group == shown.first?.group ? heading : nil,
                footer: Self.footer(of: group, at: level),
                reach: group == .build ? .nextLaunch : .env,
            ) {
                ForEach(settings) { setting in
                    SettingRow(
                        setting: setting, store: store, shaders: shaders,
                        recommended: setting.recommended(recommendation),
                        fixed: fixMark(for: setting),
                    )
                    .highlightable(setting.id.anchor(at: level), highlighted: highlighted)
                }
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
        case (.performance, .game): "Leave these on Inherit unless a game needs one."
        case (.performance, .bottle): "Defaults for every game; a game can set its own."
        default: nil
        }
    }
}

/// One setting: its control and caption, with the fix table's recommendation
/// or the fix list's mark and undo in the caption's place.
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
        let inherits = store.level == .game && setting.inherits
        switch setting.control {
        case .upscaler:
            UpscalerPicker(
                shaders: shaders,
                inherited: store.level == .game ? store.inherited(setting).choice : nil,
                note: note,
                selection: upscalerSelection,
            )
        case .toggle where !inherits:
            SettingsToggle(
                title: "\(setting.title)", caption: caption, help: setting.copy.help, note: note,
                isOn: store.flagBinding(setting),
            )
        case .toggle:
            InheritablePicker(
                title: "\(setting.title)", caption: caption, help: setting.copy.help, note: note,
                inherited: setting.label(of: store.inherited(setting)),
                selection: store.binding(setting).flagTag,
            ) {
                Text("On").tag(SettingValue.onTag)
                Text("Off").tag(SettingValue.offTag)
            }
        case let .choices(choices) where inherits, let .tuning(choices) where inherits:
            InheritablePicker(
                title: "\(setting.title)", caption: caption, help: setting.copy.help, note: note,
                inherited: setting.label(of: store.inherited(setting)),
                selection: store.binding(setting).choice,
            ) {
                SettingChoiceOptions(choices: choices)
            }
        case let .choices(choices), let .tuning(choices):
            SettingsPicker(
                title: "\(setting.title)", caption: caption, help: setting.copy.help, note: note,
                selection: store.choiceBinding(setting),
            ) {
                SettingChoiceOptions(choices: choices)
            }
        }
        if case .tuning = setting.control, store.effective(setting) == .choice(PerformanceTuning.custom.rawValue),
           store.own(setting) != nil || store.level == .bottle {
            TuningParametersRows(parameters: store.tuningParametersBinding)
        }
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

    /// What the setting does, what its value in force does, or what the value
    /// costs where it alone makes Steam restart.
    private var caption: String {
        if SettingReach.env != .clientRestart, setting.reach(store.own(setting)) == .clientRestart {
            return String(localized: "Steam restarts for this value, about 30 seconds.")
        }
        return setting.detail?(store.effective(setting)) ?? setting.copy.caption
    }

    /// The fix list's mark, or the fix table's recommendation where the row
    /// holds another value.
    private var note: SettingsRowNote? {
        if let fixed {
            return SettingsRowNote(
                text: "Set by a known fix", actionTitle: "Undo", reason: fixed.reason, action: fixed.undo,
            )
        }
        guard let recommended, store.own(setting) != recommended.value else { return nil }
        return SettingsRowNote(
            text: "Recommended: \(setting.label(of: recommended.value))", actionTitle: "Use It",
            reason: InterfaceCopy.localized(recommended.reason),
        ) {
            store.send(.set(setting.id, recommended.value))
        }
    }
}

private struct SettingChoiceOptions: View {
    let choices: [SettingChoice]

    var body: some View {
        ForEach(choices) { choice in
            Text(choice.label).tag(choice.value)
        }
    }
}

/// The three numbers behind the Custom thread-waiting preset.
private struct TuningParametersRows: View {
    @Binding var parameters: TuningParameters

    var body: some View {
        SettingsNumberField(title: "Wait spin", value: $parameters.waitSpin, range: TuningParameters.spinRange)
        SettingsNumberField(title: "Object spin", value: $parameters.objectSpin, range: TuningParameters.spinRange)
        SettingsToggle(title: "Reduce spinning after repeated misses", isOn: $parameters.adaptive)
    }
}

private extension SettingValue {
    static let onTag = "on"
    static let offTag = "off"
}

private extension Binding<SettingValue?> {
    /// A choice's stored value, `nil` where the level inherits.
    var choice: Binding<String?> {
        Binding<String?>(
            get: { wrappedValue?.choice },
            set: { wrappedValue = $0.map(SettingValue.choice) },
        )
    }

    /// A switch as a picker's tag, `nil` where the level inherits.
    var flagTag: Binding<String?> {
        Binding<String?>(
            get: { wrappedValue?.flag.map { $0 ? SettingValue.onTag : SettingValue.offTag } },
            set: { wrappedValue = $0.map { .flag($0 == SettingValue.onTag) } },
        )
    }
}

extension SettingID {
    /// The row search flashes for this setting, where search knows one.
    func anchor(at level: SettingLevel) -> SettingsAnchor? {
        switch (self, level) {
        case (.windows, .bottle): .graphicsWindows
        case (.upscaler, .bottle): .graphicsUpscaler
        case (.filter, .bottle): .graphicsFilter
        case (.mouse, .bottle): .graphicsMouse
        case (.upscaler, .game): .gamesUpscaler
        default: nil
        }
    }
}
