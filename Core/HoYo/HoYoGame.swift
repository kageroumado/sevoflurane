import Foundation

/// The HoYoverse games Sevoflurane installs through HoYoPlay's Sophon service,
/// global servers only.
nonisolated enum HoYoGame: String, CaseIterable, Codable, Sendable {
    case genshin = "hk4e_global"
    case starRail = "hkrpg_global"
    case zenless = "nap_global"

    /// HoYoPlay's id, the key of every launcher API call.
    var gameID: String {
        switch self {
        case .genshin: "gopR6Cufr3"
        case .starRail: "4ziysqXOQ8"
        case .zenless: "U5hbdsT9W7"
        }
    }

    var displayName: String {
        switch self {
        case .genshin: "Genshin Impact"
        case .starRail: "Honkai: Star Rail"
        case .zenless: "Zenless Zone Zero"
        }
    }

    var executable: String {
        switch self {
        case .genshin: "GenshinImpact.exe"
        case .starRail: "StarRail.exe"
        case .zenless: "ZenlessZoneZero.exe"
        }
    }

    /// The command-line name.
    var slug: String {
        switch self {
        case .genshin: "genshin"
        case .starRail: "starrail"
        case .zenless: "zzz"
        }
    }

    /// Whether `SteamParent.executables` names the game. Star Rail's MHYPBase
    /// protection ends it seconds in under Wine (4.5 and 4.6), so it is kept
    /// current but never added to Quick Launch.
    var launches: Bool { self != .starRail }

    /// The game whose executable sits at the top of `folder`, if any.
    static func identify(folder: URL) -> HoYoGame? {
        allCases.first { game in
            FileManager.default.fileExists(atPath: folder.appending(path: game.executable).path)
        }
    }

    /// The game a slug, biz code or display name names, in any case.
    static func named(_ word: String) -> HoYoGame? {
        let word = word.lowercased()
        return allCases.first { game in
            game.slug == word || game.rawValue == word || game.displayName.lowercased() == word
        }
    }
}

/// Sophon voice-pack fields and their names.
nonisolated enum HoYoVoice {
    /// The manifest field of a game's own files.
    static let gameField = "game"

    static let names: [String: String] = [
        "en-us": "English", "ja-jp": "Japanese", "zh-cn": "Chinese", "ko-kr": "Korean",
    ]

    static func name(_ field: String) -> String { names[field] ?? field }
}
