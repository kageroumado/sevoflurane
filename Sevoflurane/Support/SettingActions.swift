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

/// Everything a settings pane can ask for. A view sends one of these and
/// knows nothing of keys, files or the engine.
nonisolated enum SettingAction: Equatable, Sendable {
    /// Gives a setting a value at this level; `nil` hands it back to the
    /// level above.
    case set(SettingID, SettingValue?)
    case setTuningParameters(TuningParameters)
    /// Gives a library a load order for this game; `nil` takes it away.
    case setDLLOverride(library: String, order: String?)
}

nonisolated enum SettingReducer {
    /// What an action makes of a level's values. Pure: the whole of what a
    /// control can change is readable here, and testable without a disk.
    static func reduce(_ values: inout ConfigValues, _ action: SettingAction) {
        switch action {
        case let .set(id, value):
            SettingCatalog.setting(id).write(&values, value)
            // The parameters belong to the Custom preset: they arrive with it
            // and leave with it.
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

/// The real thing: the JSON store, the change trail, the env files and the
/// registry pass, all behind ``GameConfig/update(bottle:prefix:_:)``.
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
            GameConfig.update(bottle: name, prefix: SteamBottle.root, change)
        case let .game(id, name):
            GameConfig.update(game: id, bottle: name, prefix: SteamBottle.root, change)
        }
    }

    func resolved(_ setting: Setting, bottle: String, game: Int?) -> SettingValue {
        setting.resolved(bottle, game)
    }
}

/// A copy of the store in memory, for the demo, the gallery and tests: it
/// starts from what is on disk and writes nothing back.
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
