import Foundation

/// How much a run is asked to say about itself.
///
/// The engine half reaches games at their next launch through `bottle.env`;
/// the app half is read live. Level two turns itself off when the next run
/// closes, since left on it costs a gigabyte of logs.
nonisolated enum DiagnosticLevel: Int, CaseIterable, Codable, Sendable, Comparable {
    /// The run record, the event log, Wine's errors, and a collected report
    /// after a run that crashed.
    case zero = 0
    /// Plus the exception channel, the renderers' logs, present samples, and
    /// a collected report after every run.
    case one = 1
    /// Plus every library load, whole minidumps, a doctor report, and the
    /// machine sampled while the game runs.
    case two = 2

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    // MARK: - What is on

    var collectsEveryRun: Bool {
        self >= .one
    }

    var samplesPresents: Bool {
        self >= .one
    }

    var keepsWholeDumps: Bool {
        self == .two
    }

    /// How often the machine's state is logged while a game runs.
    var hostSampleInterval: Duration? {
        self == .two ? .seconds(10) : nil
    }

    var compressesReports: Bool {
        self == .two
    }

    var isSingleRun: Bool {
        self == .two
    }

    // MARK: - What the engine is told

    /// The `WINEDEBUG` channels this level adds; `+loaddll,+module` costs tens
    /// of thousands of lines per launch, so it is level two only.
    var wineChannels: String? {
        switch self {
        case .zero: nil
        case .one: "\(WineLog.levelZero),+seh"
        case .two: "\(WineLog.levelZero),+seh,+loaddll,+module"
        }
    }

    /// This level's channels folded onto the bottle's own; where both name a
    /// channel, the bottle's hand-set token wins.
    func channels(over bottle: String = WineLog.channels) -> String {
        guard let wineChannels else { return bottle }
        return WineLog.compose(wineChannels, with: bottle)
    }

    /// The renderers' own log switches, each spelled its own way, pointed at
    /// the directory the report collects.
    var rendererLines: [String] {
        guard self >= .one else { return [] }
        let directory = DebugMode.rendererLogWindowsPath
        var lines = [
            "DXMT_LOG_LEVEL=info",
            "DXMT_LOG_PATH=\(directory)",
            "DXVK_LOG_LEVEL=info",
            "DXVK_LOG_PATH=\(directory)",
            "D3DM_LOG=1",
        ]
        if self == .two {
            lines += ["SEVO_PRESENTATION_LOG=1", "SEVO_PRESENTER_LOG=1", "SEVO_GFX_LOG=1"]
        }
        return lines
    }

    /// Creates the renderer log directory, which DXMT does not make.
    static func prepareRendererLogs(prefix: URL) {
        try? FileManager.default.createDirectory(
            at: DebugMode.rendererLogDirectory(prefix: prefix), withIntermediateDirectories: true,
        )
    }

    // MARK: - What it is called

    var title: String {
        let value = switch self {
        case .zero: "Off"
        case .one: "Diagnostics"
        case .two: "Everything"
        }
        return InterfaceCopy.localized(value)
    }

    /// The level in one line, for the row under the picker.
    var caption: String {
        let value = switch self {
        case .zero: "Each game's run is recorded, and a crash collects its reports."
        case .one: "Adds Wine's exceptions, each renderer's log and a report after every run."
        case .two: "Adds every library load and whole crash dumps. Turns off after the next game."
        }
        return InterfaceCopy.localized(value)
    }

    var detail: String {
        let value = switch self {
        case .zero:
            "Each game's run is recorded, and a crash collects its reports. "
                + "Nothing measurable is spent."
        case .one:
            "Adds Wine's exception channel, each renderer's own log, and a "
                + "report after every run. Turn this on before reproducing a bug."
        case .two:
            "Adds every library a game loads, whole crash dumps, a doctor "
                + "report and the machine's state while it runs. Turns itself "
                + "off after the next game."
        }
        return InterfaceCopy.localized(value)
    }

    // MARK: - Where it is kept

    /// The level in force, shared by the app and `sevo`.
    static var current: DiagnosticLevel {
        DiagnosticLevel(rawValue: Preferences.shared.integer(forKey: key)) ?? .zero
    }

    /// Sets the level and rewrites the env files; answers the level in force.
    @discardableResult
    static func set(_ level: DiagnosticLevel, prefix: URL = SteamBottle.root) -> DiagnosticLevel {
        if level == .zero {
            Preferences.shared.removeObject(forKey: key)
        } else {
            Preferences.shared.set(level.rawValue, forKey: key)
            prepareRendererLogs(prefix: prefix)
        }
        ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: prefix)
        return current
    }

    /// Takes a single-run level off; answers whether it did.
    @discardableResult
    static func expireAfterRun(prefix: URL = SteamBottle.root) -> Bool {
        guard current.isSingleRun else { return false }
        set(.zero, prefix: prefix)
        return true
    }

    private static let key = "diagnosticLevel"

    /// `level 1 (diagnostics)`.
    var summary: String {
        "level \(rawValue) (\(title.lowercased()))"
    }
}
