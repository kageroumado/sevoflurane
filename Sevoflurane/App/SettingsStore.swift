import SwiftUI

/// One level's settings as a pane sees them, and the one way a pane changes
/// them.
///
/// ``send(_:)`` is the whole write path: the action goes through
/// ``SettingReducer``, the environment stores the result and carries it to
/// the engine, and the store reads the level back. A control therefore shows
/// what was stored, never what it asked for: one that is connected to nothing
/// snaps back under the finger.
@MainActor
@Observable
final class SettingsStore {
    let scope: SettingScope
    private(set) var values: ConfigValues
    @ObservationIgnored private let environment: any SettingsEnvironment

    init(scope: SettingScope, environment: any SettingsEnvironment = SettingsStore.processEnvironment) {
        self.scope = scope
        self.environment = environment
        values = environment.values(scope)
    }

    /// The store on disk, except in a process that must move nothing: the
    /// demo and the gallery edit a copy.
    static let processEnvironment: any SettingsEnvironment = {
        #if DEBUG
            if DemoMode.isOn || GalleryWindow.wasRequestedAtLaunch { return InMemorySettingsEnvironment() }
        #endif
        return LiveSettingsEnvironment()
    }()

    var level: SettingLevel { scope.level }

    // MARK: - Reading

    /// This level's own value; `nil` where it inherits.
    func own(_ setting: Setting) -> SettingValue? {
        setting.read(values)
    }

    /// What the level above resolves to: what Inherit stands for.
    func inherited(_ setting: Setting) -> SettingValue {
        environment.resolved(setting, bottle: scope.bottle, game: nil)
    }

    /// The value in force at this level.
    func effective(_ setting: Setting) -> SettingValue {
        own(setting) ?? environment.resolved(setting, bottle: scope.bottle, game: scope.game)
    }

    var tuningParameters: TuningParameters {
        values.tuningParameters ?? .experimental
    }

    // MARK: - Writing

    func send(_ action: SettingAction) {
        var preview = values
        SettingReducer.reduce(&preview, action)
        guard preview != values else { return }
        environment.update(scope) { SettingReducer.reduce(&$0, action) }
        values = environment.values(scope)
    }

    // MARK: - Bindings

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
