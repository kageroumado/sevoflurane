import Foundation

/// A frame-rate unlocker for Genshin Impact, which caps itself at 60 fps,
/// started beside it in the companion prefix (``SteamParent``): the engine's
/// own (``ownName``), or an executable chosen in Settings › Games.
///
/// It must share the game's prefix, engine and environment: a Wine process
/// sees only its own wineserver's processes, and one without `WINEMSYNC`
/// beside an msync server dies at once. Measured 2026-09-26 on Dormison r19:
/// 120 fps (1 % low 88) where the game alone held 60.
nonisolated enum FPSUnlocker {
    /// The executables, lowercased, it is started beside. Genshin's global and
    /// Chinese builds; the other HoYoverse games offer 120 fps in their own
    /// settings.
    static let games: Set<String> = ["genshinimpact.exe", "yuanshen.exe"]

    /// The frame rates Settings offers. The unlocker takes any number; these
    /// are the ones a Mac display runs at.
    static let targets = [60, 90, 120, 144]

    static let defaultTarget = 120

    /// How long after the game appears the unlocker starts; earlier, the
    /// value it patches may not exist yet.
    static let delay: Duration = .seconds(30)

    /// How long the game gets to appear before the unlocker gives up on it.
    static let appearDeadline: Duration = .seconds(120)

    // MARK: - Settings

    /// The unlocker's Windows executable on this Mac, or `nil` when none is
    /// chosen.
    static var executable: URL? {
        get { Preferences.shared.string(forKey: pathKey).map(URL.init(fileURLWithPath:)) }
        set { Preferences.shared.set(newValue?.path, forKey: pathKey) }
    }

    /// Whether it starts with the game. Off until the user switches it on or
    /// chooses an executable: it changes the game's memory, which HoYoverse's
    /// terms do not allow.
    static var isEnabled: Bool {
        get { Preferences.shared.object(forKey: enabledKey) as? Bool ?? false }
        set { Preferences.shared.set(newValue, forKey: enabledKey) }
    }

    static var target: Int {
        get {
            let stored = Preferences.shared.integer(forKey: targetKey)
            return stored > 0 ? stored : defaultTarget
        }
        set { Preferences.shared.set(newValue, forKey: targetKey) }
    }

    private static let pathKey = "fpsUnlockerPath"
    private static let enabledKey = "fpsUnlockerEnabled"
    private static let targetKey = "fpsUnlockerTarget"

    /// The engine's own unlocker (``Engine/fpsUnlocker``): genshin-fps-unlock's
    /// stub, loaded into the game by a program that takes the frame rate as
    /// its argument.
    static let ownName = Engine.fpsUnlockerName

    /// The unlocker a launch gets: the executable and whether it is the
    /// engine's own, which is told its target on the command line, or the
    /// user's, which reads its `fps_config.json`.
    struct Unlocker: Equatable, Sendable {
        let executable: URL
        let isSevoflurane: Bool
    }

    /// Whether a launch of `program` gets the unlocker, and which one: the
    /// executable the user chose when it is there, else the engine's own.
    static func unlocker(for program: AdoptedProgram, engine: Engine) -> Unlocker? {
        guard isEnabled, games.contains(program.url.lastPathComponent.lowercased()) else { return nil }
        return choose(user: executable, own: engine.fpsUnlocker)
    }

    /// The user's unlocker when its file exists, else the engine's own.
    static func choose(user: URL?, own: URL?) -> Unlocker? {
        if let user, FileManager.default.fileExists(atPath: user.path) {
            return Unlocker(executable: user, isSevoflurane: false)
        }
        return own.map { Unlocker(executable: $0, isSevoflurane: true) }
    }

    // MARK: - Its own configuration

    /// Points the unlocker's `fps_config.json` at this game and rate, with
    /// `AutoStart` off: a game the unlocker starts has the wrong parent and
    /// takes the kernel-driver path. Other keys are kept; a missing file is
    /// left for the unlocker to write.
    @discardableResult
    static func configure(_ unlocker: URL, game: AdoptedProgram, target: Int) -> Bool {
        let url = unlocker.deletingLastPathComponent().appendingPathComponent("fps_config.json")
        guard let data = try? Data(contentsOf: url) else { return false }
        guard var config = parse(data) else { return false }
        config["GamePath"] = SteamParent.windowsPath(game.path)
        config["FPSTarget"] = target
        config["AutoStart"] = false
        // A DLL the unlocker injects runs inside the game, which the game's
        // own protection notices; none by Sevoflurane's hand.
        config["DllList"] = [String]()
        guard let out = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys],
        ) else { return false }
        // The unlocker writes the file with a byte-order mark and reads it
        // either way.
        return (try? (Data([0xEF, 0xBB, 0xBF]) + out).write(to: url, options: .atomic)) != nil
    }

    /// The file as the unlocker writes it: UTF-8 with a byte-order mark.
    static func parse(_ data: Data) -> [String: Any]? {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data
        return (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any]
    }
}
