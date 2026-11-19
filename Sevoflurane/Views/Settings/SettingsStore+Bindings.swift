import SwiftUI

/// The store's settings as bindings for the controls that edit them.
extension SettingsStore {
    /// A setting's own value, for a control that can say Inherit.
    func binding(_ setting: Setting) -> Binding<SettingValue?> {
        Binding(
            get: { self.own(setting) },
            set: { self.send(.set(setting.id, $0)) },
        )
    }

    /// A switch at a level with no Inherit: it shows the value in force and
    /// writes the level's own.
    func flagBinding(_ setting: Setting) -> Binding<Bool> {
        Binding(
            get: { self.effective(setting).flag ?? false },
            set: { self.send(.set(setting.id, .flag($0))) },
        )
    }

    /// A choice at a level with no Inherit.
    func choiceBinding(_ setting: Setting) -> Binding<String> {
        Binding(
            get: { self.effective(setting).choice ?? "" },
            set: { self.send(.set(setting.id, .choice($0))) },
        )
    }

    var tuningParametersBinding: Binding<TuningParameters> {
        Binding(
            get: { self.tuningParameters },
            set: { self.send(.setTuningParameters($0)) },
        )
    }
}
