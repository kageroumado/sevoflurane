import Foundation

/// The HoYoverse games Sevoflurane downloads and updates itself, from the
/// same servers and in the same format HoYoPlay uses (Sophon).
///
/// The global (`_global`) servers only: the Chinese builds come from other
/// hosts with other game ids and have never been tried here.
nonisolated enum HoYoGame: String, CaseIterable, Codable, Sendable {
    case genshin = "hk4e_global"
    case starRail = "hkrpg_global"
    case zenless = "nap_global"

    /// HoYoPlay's id for the game, which every launcher API call is keyed by.
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

    /// The executable at the top of an installed folder.
    var executable: String {
        switch self {
        case .genshin: "GenshinImpact.exe"
        case .starRail: "StarRail.exe"
        case .zenless: "ZenlessZoneZero.exe"
        }
    }

    /// A short name for the command line: `genshin`, `starrail`, `zzz`.
    var slug: String {
        switch self {
        case .genshin: "genshin"
        case .starRail: "starrail"
        case .zenless: "zzz"
        }
    }

    /// Whether Sevoflurane can start the game once it is installed, which is
    /// whether `SteamParent.executables` names it. Star Rail's protection
    /// ends the game a few seconds in under Wine even behind that parent
    /// (MHYPBase, 4.5 and 4.6, 2026-09-29), so it is downloaded and kept
    /// current but never added to Quick Launch.
    var launches: Bool { self != .starRail }

    /// The game whose executable sits at the top of `folder`, if any.
    static func identify(folder: URL) -> HoYoGame? {
        allCases.first { game in
            FileManager.default.fileExists(atPath: folder.appending(path: game.executable).path)
        }
    }

    /// The game a command-line word names: its slug, its biz code or its
    /// display name, in any case.
    static func named(_ word: String) -> HoYoGame? {
        let word = word.lowercased()
        return allCases.first { game in
            game.slug == word || game.rawValue == word || game.displayName.lowercased() == word
        }
    }
}

/// The Sophon category a voice-over pack is published under, and the name a
/// person knows it by.
nonisolated enum HoYoVoice {
    /// The manifest field of a game's own files, beside which the voice packs
    /// are published.
    static let gameField = "game"

    static let names: [String: String] = [
        "en-us": "English", "ja-jp": "Japanese", "zh-cn": "Chinese", "ko-kr": "Korean",
    ]

    static func name(_ field: String) -> String { names[field] ?? field }
}
