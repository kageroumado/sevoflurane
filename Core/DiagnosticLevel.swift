import Foundation

/// How much a run is asked to say about itself.
///
/// Level zero is always on and costs nothing measurable: the run record, the
/// app's own event trail, and Wine's errors. Level one is what someone
/// reproducing a bug turns on — the exception channel, the renderers' own
/// logs, and a collected report after every run rather than only after a bad
/// one. Level two is for a bug that survives level one: every library load,
/// whole minidumps, a doctor report, the machine sampled while the game runs,
/// and the report compressed when it closes.
///
/// The engine half reaches games at their next launch through `bottle.env`
/// (``ConfigMaterializer``), the same way the settings hierarchy does. The app
/// half is read live, so a level set from `sevo` while the app runs takes
/// effect on the next sample.
///
/// Level two turns itself off when the next run closes: it is the level
/// someone sets to catch one crash, and the cost of leaving it on is a
/// gigabyte of logs nobody asked for.
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

    /// Whether the run's report is collected whatever the run's ending was.
    var collectsEveryRun: Bool {
        self >= .one
    }

    /// Whether the driver's present counter is sampled at one second.
    var samplesPresents: Bool {
        self >= .one
    }

    /// Whether minidumps are copied whole rather than named and measured.
    var keepsWholeDumps: Bool {
        self == .two
    }

    /// Whether the machine's state is written to the event log while a game
    /// runs, and how often.
    var hostSampleInterval: Duration? {
        self == .two ? .seconds(10) : nil
    }

    /// Whether a report is compressed when the run closes.
    var compressesReports: Bool {
        self == .two
    }

    /// Whether the level takes itself off at the end of the next run.
    var isSingleRun: Bool {
        self == .two
    }

    // MARK: - What the engine is told

    /// The `WINEDEBUG` channels this level adds to the bottle's own, or `nil`
    /// at level zero, where the bottle's setting is the whole of it.
    ///
    /// `+seh` costs a line at an exception and nothing while a game runs;
    /// `+loaddll,+module` costs a line per library, which is tens of thousands
    /// per launch — which is why it is a level of its own.
    var wineChannels: String? {
        switch self {
        case .zero: nil
        case .one: "\(WineLog.levelZero),+seh"
        case .two: "\(WineLog.levelZero),+seh,+loaddll,+module"
        }
    }

    /// What a game actually carries: this level's channels folded onto the
    /// bottle's own, so a `wine-debug` string set by hand keeps its channels
    /// through a level instead of being replaced by one. Where both name a
    /// channel the bottle's token stands, since that is the one reached for
    /// deliberately.
    func channels(over bottle: String = WineLog.channels) -> String {
        guard let wineChannels else { return bottle }
        return WineLog.compose(wineChannels, with: bottle)
    }

    /// What the level writes into `bottle.env` beyond the channels: the
    /// renderers' own logs, each into the directory the report collects.
    ///
    /// The three renderers spell it three ways — DXMT takes a level and a
    /// directory, DXVK a level and a file, D3DMetal a single switch — so all
    /// three are named rather than one being derived from another.
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

    /// The directory the renderers are told to write into, as macOS sees it.
    /// Created here because DXMT opens a file in it and does not make it.
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

    /// Sets the level and rewrites the bottle's env files, so the next game
    /// launched carries it. Answers the level that is now in force.
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

    /// Takes a single-run level off, now that its run has closed. Answers
    /// whether it did anything, which is what the caller says out loud.
    @discardableResult
    static func expireAfterRun(prefix: URL = SteamBottle.root) -> Bool {
        guard current.isSingleRun else { return false }
        set(.zero, prefix: prefix)
        return true
    }

    private static let key = "diagnosticLevel"

    /// `level 1 (diagnostics)` — what `sevo diag status` and the report window
    /// both print.
    var summary: String {
        "level \(rawValue) (\(title.lowercased()))"
    }
}
