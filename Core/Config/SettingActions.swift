import Foundation

/// Which level of the hierarchy a pane edits.
nonisolated enum SettingScope: Hashable, Sendable {
    case bottle(String)
    case game(Int, bottle: String)

    var level: SettingLevel {
        switch self {
        case .bottle: .bottle
        case .game: .game
        }
    }

    var bottle: String {
        switch self {
        case let .bottle(name), let .game(_, name): name
        }
    }

    var game: Int? {
        if case let .game(id, _) = self { id } else { nil }
    }
}

/// Everything a settings pane can ask for.
nonisolated enum SettingAction: Equatable, Sendable {
    /// Gives a setting a value at this level; `nil` hands it back to the
    /// level above.
    case set(SettingID, SettingValue?)
    case setTuningParameters(TuningParameters)
    /// Gives a library a load order for this game; `nil` takes it away.
    case setDLLOverride(library: String, order: String?)
    /// Sets a variable at this level; `nil` takes it away. A pair
    /// ``UserEnvironment/problem(name:value:)`` refuses is ignored.
    case setEnvironment(name: String, value: String?)
}

nonisolated enum SettingReducer {
    /// What an action makes of a level's values; pure.
    static func reduce(_ values: inout ConfigValues, _ action: SettingAction) {
        switch action {
        case let .set(id, value):
            SettingCatalog.setting(id).write(&values, value)
            // Parameters exist only under the Custom preset.
            if id == .tuning {
                values.tuningParameters = values.tuning == .custom
                    ? values.tuningParameters ?? .experimental : nil
            }
        case let .setTuningParameters(parameters):
            guard values.tuning == .custom else { return }
            values.tuningParameters = parameters
        case let .setDLLOverride(library, order):
            var table = values.dllOverrides ?? [:]
            table[library] = order
            values.dllOverrides = table.isEmpty ? nil : table
        case let .setEnvironment(name, value):
            if let value, UserEnvironment.problem(name: name, value: value) != nil { return }
            var table = values.environment ?? [:]
            table[name] = value
            values.environment = table.isEmpty ? nil : table
        }
    }
}

/// Where a level's values are kept and what a change to them sets in motion.
protocol SettingsEnvironment: Sendable {
    /// The level's own values, as stored.
    nonisolated func values(_ scope: SettingScope) -> ConfigValues
    /// Stores the changed values and carries them to what the engine reads.
    nonisolated func update(_ scope: SettingScope, _ change: (inout ConfigValues) -> Void)
    /// What the hierarchy resolves a setting to, for the bottle or for a game.
    nonisolated func resolved(_ setting: Setting, bottle: String, game: Int?) -> SettingValue
}

/// The store on disk, through ``GameConfig/update(bottle:prefix:inBackground:_:)``,
/// written off the main actor.
nonisolated struct LiveSettingsEnvironment: SettingsEnvironment {
    func values(_ scope: SettingScope) -> ConfigValues {
        switch scope {
        case let .bottle(name): GameConfig.bottle(name)
        case let .game(id, _): GameConfig.game(id)
        }
    }

    func update(_ scope: SettingScope, _ change: (inout ConfigValues) -> Void) {
        switch scope {
        case let .bottle(name):
            GameConfig.update(bottle: name, prefix: SteamBottle.root, inBackground: true, change)
        case let .game(id, name):
            GameConfig.update(game: id, bottle: name, prefix: SteamBottle.root, inBackground: true, change)
        }
    }

    func resolved(_ setting: Setting, bottle: String, game: Int?) -> SettingValue {
        setting.resolved(bottle, game)
    }
}

/// An in-memory overlay of the store for the demo, gallery and tests; it
/// writes nothing back.
final nonisolated class InMemorySettingsEnvironment: SettingsEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [SettingScope: ConfigValues]
    private let fallback: any SettingsEnvironment

    /// Every update this environment took, for a test to read.
    private(set) var updates: [SettingScope] = []

    init(seed: [SettingScope: ConfigValues] = [:], over fallback: any SettingsEnvironment = LiveSettingsEnvironment()) {
        stored = seed
        self.fallback = fallback
    }

    func values(_ scope: SettingScope) -> ConfigValues {
        lock.withLock { stored[scope] } ?? fallback.values(scope)
    }

    func update(_ scope: SettingScope, _ change: (inout ConfigValues) -> Void) {
        var values = values(scope)
        change(&values)
        lock.withLock {
            stored[scope] = values
            updates.append(scope)
        }
    }

    func resolved(_ setting: Setting, bottle: String, game: Int?) -> SettingValue {
        if let game, let own = setting.read(values(.game(game, bottle: bottle))) { return own }
        if let own = setting.read(values(.bottle(bottle))) { return own }
        return fallback.resolved(setting, bottle: bottle, game: nil)
    }
}
