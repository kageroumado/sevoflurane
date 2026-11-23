import Foundation
import Observation

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
    /// The catalog's groups that offer a row at this level, each with its
    /// rows. Whether a row is offered for a game can read Steam's app cache.
    private(set) var groups: [(group: SettingGroup, settings: [Setting])]
    /// What the fix list set on the game at its first launch; `nil` at the
    /// bottle level and for a game it never touched.
    private(set) var appliedFixes: AppliedFixes?
    @ObservationIgnored private let environment: any SettingsEnvironment

    init(scope: SettingScope, environment: any SettingsEnvironment = SettingsStore.processEnvironment) {
        self.scope = scope
        self.environment = environment
        values = environment.values(scope)
        groups = Self.groups(for: scope)
        appliedFixes = scope.game.flatMap { FixLedger.record(for: $0) }
    }

    #if DEBUG
        /// A game's store that holds what the fix list is said to have set,
        /// for the gallery.
        convenience init(scope: SettingScope, environment: any SettingsEnvironment, fixtureFixes: AppliedFixes) {
            self.init(scope: scope, environment: environment)
            appliedFixes = fixtureFixes
        }
    #endif

    private static func groups(for scope: SettingScope) -> [(group: SettingGroup, settings: [Setting])] {
        SettingGroup.allCases
            .map { ($0, SettingCatalog.settings(in: $0, at: scope.level, game: scope.game)) }
            .filter { !$0.settings.isEmpty }
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

    /// Puts `keys` (all when `nil`) back as they were before the fix list, as
    /// the notification's Undo does, and reads the game's values back.
    func undoFixes(_ keys: Set<String>?) {
        guard let game = scope.game else { return }
        appliedFixes = FixLedger.undo(appID: game, keys: keys, inBackground: true)
        values = environment.values(scope)
    }
}
