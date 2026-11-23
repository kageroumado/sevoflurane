import Foundation

/// The community game database's website: how each game runs on which Mac,
/// from the runs players share.
nonisolated enum GameDatabase {
    /// The database's front page, in Simplified Chinese where that is the
    /// reader's first language.
    static var pageURL: URL {
        let language = Locale.preferredLanguages.first?.hasPrefix("zh-Hans") == true ? "lang=zh-CN&" : ""
        return URL(string: "https://kagerou.glass/sevoflurane/games/?\(language)from=app")!
    }
}
