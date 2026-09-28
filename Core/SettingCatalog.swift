import Foundation

// The settings a bottle sets for every game and a game sets for itself:
// one ``Setting`` each, holding everything a row, a command line or a test
// needs to know about it. A pane draws the catalog; it names no key.

nonisolated enum SettingID: String, CaseIterable, Sendable {
    case renderer
    case windows
    case upscaler
    case filter
    case retina
    case emulateModeset
    case fps
    case fpsGraph
    case hud
    case mouse
    case cursorConfine
    case tuning
    case processors
    case unifiedMemory
    case largeAddressAware
    case avx
}

/// The groups a pane shows, in order.
nonisolated enum SettingGroup: String, CaseIterable, Sendable {
    case picture
    case mouse
    case performance

    var title: String {
        let value = switch self {
        case .picture: "Picture"
        case .mouse: "Mouse"
        case .performance: "Performance and compatibility"
        }
        return InterfaceCopy.localized(value)
    }
}

/// A level of the hierarchy a pane edits.
nonisolated enum SettingLevel: Sendable {
    case bottle
    case game
}

/// A value as a control holds it, whatever type the key stores.
nonisolated enum SettingValue: Equatable, Sendable {
    case flag(Bool)
    /// A case's raw value, or a shader package's name.
    case choice(String)

    var flag: Bool? {
        if case let .flag(on) = self { on } else { nil }
    }

    var choice: String? {
        if case let .choice(value) = self { value } else { nil }
    }
}

nonisolated struct SettingChoice: Equatable, Sendable, Identifiable {
    let value: String
    let label: String

    var id: String { value }

    init(value: String, label: String) {
        self.value = value
        self.label = InterfaceCopy.localized(label)
    }
}

/// Which control a row is.
nonisolated enum SettingControl: Equatable, Sendable {
    case toggle
    case choices([SettingChoice])
    /// Choices that come from the shader store, with their own line and a
    /// download behind some of them.
    case upscaler
    /// As `choices`, with ``TuningParameters`` to edit under Custom.
    case tuning([SettingChoice])
}

/// What takes a value to a running game — the thing a test looks at to see
/// that a control is connected to anything.
nonisolated enum SettingCarrier: Equatable, Sendable {
    /// Lines of the env files the engine reads at every process start.
    case environment([String])
    /// A value of the prefix's registry, by name.
    case registry(String)
    /// A renderer's payload directory in the game's env file where the
    /// engine can hand one game a renderer, and otherwise the client, which
    /// restarts on that renderer around the game's launch.
    case rendererPayload
}

nonisolated struct Setting: Identifiable, Sendable {
    let id: SettingID
    let group: SettingGroup
    let levels: Set<SettingLevel>
    let copy: SettingCopy
    let control: SettingControl
    let carrier: SettingCarrier
    /// This level's own value, `nil` where it inherits.
    let read: @Sendable (ConfigValues) -> SettingValue?
    let write: @Sendable (inout ConfigValues, SettingValue?) -> Void
    /// What the hierarchy resolves to for a bottle, or for a game in it.
    let resolved: @Sendable (_ bottle: String, _ game: Int?) -> SettingValue
    /// What a change costs to reach a game that sets `own`.
    let reach: @Sendable (_ own: SettingValue?) -> SettingReach
    /// The value the fix table names for this key, and why.
    let recommended: @Sendable (KnownFixes.Recommendation) -> (value: SettingValue, reason: String)?
    /// The line under the row where it follows the value in force; the
    /// copy's own caption stands elsewhere.
    var detail: (@Sendable (SettingValue) -> String?)?

    var title: String { copy.title }

    /// The label of a value, for the line that says what Inherit stands for.
    func label(of value: SettingValue) -> String {
        switch (control, value) {
        case let (_, .flag(on)): InterfaceCopy.localized(on ? "On" : "Off")
        case let (.choices(choices), .choice(raw)), let (.tuning(choices), .choice(raw)):
            choices.first { $0.value == raw }?.label ?? raw
        case let (_, .choice(raw)): raw
        }
    }
}

// MARK: - Builders

nonisolated extension Setting {
    /// A switch stored as a `Bool?`.
    static func flag(
        _ id: SettingID, in group: SettingGroup, levels: Set<SettingLevel> = [.bottle, .game],
        key: any WritableKeyPath<ConfigValues, Bool?> & Sendable, copy: SettingCopy, carrier: SettingCarrier,
        reach: @escaping @Sendable (SettingValue?) -> SettingReach = { _ in .env },
    ) -> Setting {
        Setting(
            id: id, group: group, levels: levels, copy: copy, control: .toggle, carrier: carrier,
            read: { $0[keyPath: key].map(SettingValue.flag) },
            write: { $0[keyPath: key] = $1?.flag },
            resolved: { .flag(GameConfig.resolve(key, bottle: $0, game: $1).value) },
            reach: reach,
            recommended: { table in
                table.fix(setting: key).flatMap { fix in
                    fix.values[keyPath: key].map { (.flag($0), fix.reason) }
                }
            },
        )
    }

    /// A choice among an enum's cases, stored by raw value.
    static func choice<Choice: RawRepresentable & CaseIterable & Sendable>(
        _ id: SettingID, in group: SettingGroup, levels: Set<SettingLevel> = [.bottle, .game],
        key: any WritableKeyPath<ConfigValues, Choice?> & Sendable, label: KeyPath<Choice, String>,
        offering cases: [Choice] = Array(Choice.allCases), copy: SettingCopy, carrier: SettingCarrier,
        control: ([SettingChoice]) -> SettingControl = { .choices($0) },
        resolved: (@Sendable (String, Int?) -> SettingValue)? = nil,
        reach: @escaping @Sendable (SettingValue?) -> SettingReach = { _ in .env },
        detail: (@Sendable (SettingValue) -> String?)? = nil,
    ) -> Setting where Choice.RawValue == String {
        let choices = cases.map { SettingChoice(value: $0.rawValue, label: $0[keyPath: label]) }
        return Setting(
            id: id, group: group, levels: levels, copy: copy, control: control(choices), carrier: carrier,
            read: { $0[keyPath: key].map { .choice($0.rawValue) } },
            write: { $0[keyPath: key] = $1?.choice.flatMap(Choice.init(rawValue:)) },
            resolved: resolved ?? { .choice(GameConfig.resolve(key, bottle: $0, game: $1).value.rawValue) },
            reach: reach,
            recommended: { table in
                table.fix(setting: key).flatMap { fix in
                    fix.values[keyPath: key].map { (.choice($0.rawValue), fix.reason) }
                }
            },
            detail: detail,
        )
    }
}

// MARK: - The catalog

nonisolated enum SettingCatalog {
    /// Every setting, in the order a pane shows them.
    static let all: [Setting] = [
        // Automatic is the bottle's business — it consults CrossOver's own
        // per-game database — so a game names a layer or inherits. The bottle's
        // own renderer is Settings › Graphics', which is what a game inherits.
        .choice(
            .renderer, in: .picture, levels: [.game], key: \.renderer, label: \.label,
            offering: Renderer.allCases.filter { $0 != .auto },
            copy: SettingCopy(
                title: "Renderer",
                help: SettingCopy.renderers(Renderer.allCases.filter { $0 != .auto }),
            ),
            carrier: .rendererPayload,
            resolved: { _, _ in .choice(BottleGraphics.currentSelection().renderer.rawValue) },
            reach: { own in .renderer(own?.choice.flatMap(Renderer.init(rawValue:))) },
        ),
        .choice(
            .windows, in: .picture, key: \.windows, label: \.label, copy: .windows,
            carrier: .environment(["SEVO_RESIZABLE_WINDOWS"]),
        ),
        Setting(
            id: .upscaler, group: .picture, levels: [.bottle, .game],
            copy: SettingCopy(title: "Upscaler", help: SettingCopy.scaling),
            control: .upscaler, carrier: .environment(["SEVO_UPSCALER"]),
            read: { $0.upscaler.map(SettingValue.choice) },
            write: { $0.upscaler = $1?.choice },
            resolved: { .choice(GameConfig.upscaler(bottle: $0, game: $1).value) },
            reach: { _ in .env },
            recommended: { table in
                table.fix(setting: \.upscaler).flatMap { fix in
                    fix.values.upscaler.map { (.choice($0), fix.reason) }
                }
            },
        ),
        .choice(
            .filter, in: .picture, key: \.filter, label: \.label,
            copy: SettingCopy(title: "Final filter", help: SettingCopy.scaling),
            carrier: .environment(["SEVO_FINAL_FILTER"]),
            detail: { $0.choice.flatMap(FinalFilter.init(rawValue:))?.detail },
        ),
        // Bottle-wide alone: `winemac.drv` reads it with no app key, so that
        // the DPI and the monitor sizes are one answer for every process.
        .flag(
            .retina, in: .picture, levels: [.bottle], key: \.retina, copy: .retina,
            carrier: .registry("RetinaMode"), reach: { _ in .registry },
        ),
        .flag(
            .emulateModeset, in: .picture, key: \.emulateModeset, copy: .modeset,
            carrier: .registry("EmulateModeset"), reach: { _ in .registry },
        ),
        .flag(.fps, in: .picture, key: \.fps, copy: .fps, carrier: .environment(["SEVO_FPS"])),
        .flag(.fpsGraph, in: .picture, key: \.fpsGraph, copy: .fpsGraph, carrier: .environment(["SEVO_FPS_GRAPH"])),
        .flag(.hud, in: .picture, key: \.hud, copy: .hud, carrier: .environment(["MTL_HUD_ENABLED"])),
        .choice(
            .mouse, in: .mouse, key: \.mouse, label: \.label, copy: .mouse,
            carrier: .environment(["SEVO_LINEAR_MOUSE"]),
        ),
        .flag(
            .cursorConfine, in: .mouse, key: \.cursorConfine, copy: .cursorConfine,
            carrier: .environment(["SEVO_CURSOR_CONFINE"]),
        ),
        .choice(
            .tuning, in: .performance, key: \.tuning, label: \.label, copy: .tuning,
            carrier: .environment(["SEVO_WAIT_SPIN", "SEVO_WAIT_SPIN_ADAPT", "SEVO_OBJECT_SPIN"]),
            control: { .tuning($0) },
        ),
        Setting(
            id: .processors, group: .performance, levels: [.bottle, .game], copy: .processors,
            control: .choices(SettingCatalog.processorChoices), carrier: .environment(["SEVO_CPU_COUNT"]),
            read: { $0.processors.map { .choice(String($0)) } },
            write: { $0.processors = $1?.choice.flatMap { Int($0) } },
            resolved: { .choice(String(GameConfig.processors(bottle: $0, game: $1).value)) },
            reach: { _ in .env },
            recommended: { table in
                table.fix(setting: \.processors).flatMap { fix in
                    fix.values.processors.map { (.choice(String($0)), fix.reason) }
                }
            },
        ),
        .flag(
            .unifiedMemory, in: .performance, key: \.unifiedMemory, copy: .unifiedMemory,
            carrier: .environment(["SEVO_FORCE_UMA"]),
        ),
        .flag(
            .largeAddressAware, in: .performance, key: \.largeAddressAware, copy: .largeAddressAware,
            carrier: .environment(["SEVO_LARGE_ADDRESS_AWARE"]),
        ),
        .flag(.avx, in: .performance, key: \.avx, copy: .avx, carrier: .environment(["ROSETTA_ADVERTISE_AVX"])),
    ]

    /// Every processor, then the caps a game that runs one busy thread per
    /// processor is offered, by the count `SEVO_CPU_COUNT` takes.
    static let processorChoices = [
        SettingChoice(value: "0", label: "All"),
        SettingChoice(value: "8", label: "8"),
        SettingChoice(value: "6", label: "6"),
        SettingChoice(value: "4", label: "4"),
    ]

    static func setting(_ id: SettingID) -> Setting {
        all.first { $0.id == id }!
    }

    static func settings(in group: SettingGroup, at level: SettingLevel) -> [Setting] {
        all.filter { $0.group == group && $0.levels.contains(level) }
    }
}
