import Foundation

/// A Steam app that serves a Mac through a kagerou app of its own: its window
/// never draws under Wine, but what Steam downloads for it is used by the
/// partner. Wallpaper Engine is one: its Workshop subscriptions become video
/// wallpapers through Phosphene.
nonisolated struct GameCompanion: Codable, Sendable, Equatable {
    let appID: Int
    let name: String
    /// The kagerou app that uses the downloads.
    let partner: String
    let partnerBundleID: String
    /// Opens the partner where the downloads show.
    let openURL: URL
    /// Where to get the partner.
    let pageURL: URL
    /// The strip's reason line, and the body of the Play alert.
    let reason: String

    static let wallpaperEngine = GameCompanion(
        appID: 431_960,
        name: "Wallpaper Engine",
        partner: "Phosphene",
        partnerBundleID: "glass.kagerou.phosphene",
        openURL: URL(string: "phosphene://library/wallpaper-engine")!,
        pageURL: URL(string: "https://kagerou.glass/phosphene/?from=sevoflurane")!,
        reason: "Subscribe to wallpapers on the Workshop; Phosphene finds them and plays them as your Mac's wallpaper.",
    )

    static let all: [Int: GameCompanion] = [wallpaperEngine.appID: wallpaperEngine]

    /// `{431960: true}`: the page scripts treat these apps as games, which
    /// Steam files under Software.
    static var appIDsLiteral: String {
        "{" + all.keys.sorted().map { "\($0): true" }.joined(separator: ", ") + "}"
    }
}
