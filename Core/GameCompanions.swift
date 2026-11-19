import Foundation

/// A Steam app whose downloads a kagerou partner app uses on the Mac, such as
/// Wallpaper Engine's Workshop items in Phosphene.
nonisolated struct GameCompanion: Codable, Sendable, Equatable {
    let appID: Int
    let name: String
    let partner: String
    let partnerBundleID: String
    /// Opens the partner where the downloads show.
    let openURL: URL
    let workshopURL: URL
    /// Where to get the partner.
    let pageURL: URL
    /// The strip's reason line and the Play alert's body.
    let reason: String

    static let wallpaperEngine = GameCompanion(
        appID: 431_960,
        name: "Wallpaper Engine",
        partner: "Phosphene",
        partnerBundleID: "glass.kagerou.phosphene",
        openURL: URL(string: "phosphene://library/wallpaper-engine")!,
        workshopURL: URL(string: "steam://url/SteamWorkshopPage/431960")!,
        pageURL: URL(string: "https://kagerou.glass/phosphene/?from=sevoflurane")!,
        reason: "Subscribe to wallpapers on the Workshop; Phosphene finds them and plays them as your Mac's wallpaper.",
    )

    static let all: [Int: GameCompanion] = [wallpaperEngine.appID: wallpaperEngine]

    /// `{431960: true}`, so page scripts treat these Software apps as games.
    static var appIDsLiteral: String {
        "{" + all.keys.sorted().map { "\($0): true" }.joined(separator: ", ") + "}"
    }
}
