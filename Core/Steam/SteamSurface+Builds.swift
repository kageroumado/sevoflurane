import Foundation

/// The two builds of Steam's UI, and where the injected scripts find the
/// same things in each.
///
/// A webpack build keeps a module registry on `window.webpackChunksteamui`
/// and writes every CSS-module class map as an object keyed by the class's
/// source name, `{PlayButton:"_3ydigb…"}`. A build of ES modules (Vite and
/// Rollup) has neither: chunks import each other, and a class is a string
/// constant beside the markup that carries it. There the scripts read a
/// class from the chunk's text beside a token no minifier touches
/// (``ClassRecipe``), find an element through its component's props, and
/// reach Steam's objects through the modules the page's entry script imports.
nonisolated extension SteamSurface {
    /// The bundler a client's UI is built with.
    enum Build: String, Codable, Sendable {
        case webpack
        /// ES modules, as Vite and Rollup write them.
        case modules
    }

    /// One class map the injected scripts read.
    enum ClassGroup: String, CaseIterable, Codable, Sendable {
        case strip
        case play
        case bar
        case button
        case search
        case row
        case tile
        case filters

        /// The keys by which the webpack module holding the map is found.
        var signature: [String] {
            switch self {
            case .strip: ["DeckVerifiedInfo"]
            case .play: ["PlayButtonContainer", "StreamingSelector"]
            case .bar: ["ActionSection", "GameStatsSection"]
            case .button: ["AppDetailsButton"]
            case .search: ["AdvancedSearchContainer"]
            case .row: ["GameListEntryContainer"]
            case .tile: ["LibraryItemBox"]
            case .filters: ["ViewFiltersBar"]
            }
        }

        /// The longest webpack module source the scripts read for the map.
        var limit: Int {
            self == .strip ? deckStripModuleLimit : classMapModuleLimit
        }

        /// Every key of the map the scripts name.
        var keys: [String] {
            switch self {
            case .strip: ["DeckVerifiedInfo", "Container"]
            case .play: ["PlayButtonContainer", "StreamingSelector", "PlayButton", "ButtonChild", "ShowingStreaming"]
            case .bar:
                [
                    "ActionSection", "GameStatsSection", "GameStat", "GameStatIcon", "GameStatRight", "PlayBarLabel",
                    "PlayBarDetailLabel", "ClickablePlayBarItem",
                ]
            case .button: ["AppDetailsButton"]
            case .search: ["AdvancedSearchContainer", "Container"]
            case .row: ["GameListEntryContainer"]
            case .tile: ["LibraryItemBox"]
            case .filters: ["ViewFiltersBar", "Filters", "CheckboxWithImage", "Active"]
            }
        }

        var name: String {
            switch self {
            case .strip: "the Deck compatibility strip's classes"
            case .play: "the Play button's classes"
            case .bar: "the play bar's classes"
            case .button: "the game page's compact button class"
            case .search: "the library search's classes"
            case .row: "the left list's row classes"
            case .tile: "the grid's tile classes"
            case .filters: "the library filter bar's classes"
            }
        }

        var use: String {
            switch self {
            case .strip: "placing the Mac compatibility strip under a game page's tab bar"
            case .play: "the Install button's version mark and the ▾ beside it"
            case .bar: "the play bar's Version entry"
            case .button: "the Version entry's button, like Cloud Status's"
            case .search: "the Mac filter chip beside the search field"
            case .row: "a Mac verdict on every game's row"
            case .tile: "a Mac verdict on every game's tile"
            case .filters: "the Mac filter chip in the filter bar"
            }
        }

        /// How the same need is met on a build of ES modules.
        var modulesAnchor: ModulesAnchor {
            switch self {
            case .strip: .props(linksBarProps, markup: ["role:\"link\""])
            default: .recipes(classRecipes.filter { $0.group == self })
            }
        }
    }

    /// Where a build of ES modules holds what a webpack class map gave.
    enum ModulesAnchor: Sendable, Equatable {
        /// Each class, read from a chunk's text.
        case recipes([ClassRecipe])
        /// An element found through its component's props, which a
        /// minifier leaves as written. `markup` is text of the chunk that
        /// draws the elements the search starts from.
        case props([String], markup: [String])
    }

    /// Where one class of a build of ES modules is written: the argument of
    /// a `className:` beside a token of Steam's source that minifying keeps
    /// (a localization key, a property name, a string).
    ///
    /// The `className:` is the one `skip` places before or after the token.
    /// Its value is a class literal, a constant holding one, or a call
    /// joining several, of which `argument` picks one (negative counts from
    /// the end; `shown&&X` names `X`). A constant is read at its nearest
    /// definition before the place it is used.
    struct ClassRecipe: Sendable, Equatable, Codable {
        let group: ClassGroup
        /// The class's name in Steam's source, and in the webpack class map.
        let key: String
        /// The token the class is written beside.
        let anchor: String
        /// A second token within ``reach`` characters of the first, for a
        /// token that occurs in several places.
        let beside: String
        let reach: Int
        /// Whether the `className:` follows the token.
        let after: Bool
        /// How many `className:` to pass over first.
        let skip: Int
        let argument: Int
        /// Whether the scripts draw without this class.
        let optional: Bool

        init(
            _ group: ClassGroup, _ key: String, beside anchor: String, near beside: String = "", within reach: Int = 1500,
            after: Bool = false, skip: Int = 0, argument: Int = 0, optional: Bool = false,
        ) {
            self.group = group
            self.key = key
            self.anchor = anchor
            self.beside = beside
            self.reach = reach
            self.after = after
            self.skip = skip
            self.argument = argument
            self.optional = optional
        }

        enum CodingKeys: String, CodingKey {
            case group
            case key
            case anchor
            case beside
            case reach
            case after
            case skip
            case argument
            case optional
        }
    }

    /// The global a webpack build keeps its module registry on.
    static let webpackRegistry = "webpackChunksteamui"

    /// The props of the component that draws a game page's row of links
    /// (Store Page, Community Hub…), under which the compatibility strip goes.
    static let linksBarProps = ["workshopVisible", "marketPresence"]

    private static let achievements = "#AppDetails_SectionTitle_Achievements"
    private static let playButtonRef = "ref:this.m_elActionButtonRef"

    /// Every class the scripts read from a chunk's text.
    static let classRecipes: [ClassRecipe] = [
        // The Play button: a container, the button with its ref, Steam's own ▾.
        ClassRecipe(.play, "PlayButton", beside: playButtonRef),
        ClassRecipe(.play, "ButtonChild", beside: playButtonRef, argument: 1),
        ClassRecipe(.play, "ShowingStreaming", beside: playButtonRef, skip: 1, argument: 5, optional: true),
        ClassRecipe(.play, "StreamingSelector", beside: "#GameAction_PlayFrom", near: "onMouseUp:", within: 200),

        // The play bar: the section of stats, and the Achievements stat's parts.
        ClassRecipe(.bar, "GameStatsSection", beside: "BUserHasContentToClaim(this.props.details.unAppID);", after: true),
        ClassRecipe(.bar, "GameStat", beside: achievements, near: "MyAchievements", skip: 3),
        ClassRecipe(.bar, "GameStatIcon", beside: achievements, near: "MyAchievements", skip: 2),
        ClassRecipe(.bar, "GameStatRight", beside: achievements, near: "MyAchievements", skip: 1),
        ClassRecipe(.bar, "PlayBarLabel", beside: achievements, near: "MyAchievements"),
        ClassRecipe(.bar, "PlayBarDetailLabel", beside: achievements, near: "MyAchievements", after: true, skip: 1),
        ClassRecipe(
            .bar, "ClickablePlayBarItem", beside: "#AppDetails_SectionTitle_CloudStatus", near: "force_icon:", within: 200,
            after: true,
        ),

        // The compact button: a pure component that hands its children on.
        // No token of Steam's source sits beside it, so its shape is the anchor.
        ClassRecipe(
            .button, "AppDetailsButton", beside: "PureComponent{render(){",
            near: "children:this.props.children})}};function", within: 200, after: true, skip: 1,
        ),

        ClassRecipe(.search, "Container", beside: "ref:this.m_containerDivRef", near: "#FilterEdit_SearchPrompt"),
        ClassRecipe(.search, "AdvancedSearchContainer", beside: "#FilterEdit_AdvancedTooltip"),
        ClassRecipe(.row, "GameListEntryContainer", beside: "includeMultiSelect:!0,children:", argument: -1),
        ClassRecipe(.tile, "LibraryItemBox", beside: "hoverDelay:300,onOKButton:"),
        ClassRecipe(.filters, "ViewFiltersBar", beside: "#GameList_View_Platform_Linux", skip: 1),
        ClassRecipe(.filters, "Filters", beside: "#GameList_View_Platform_Linux"),
        ClassRecipe(.filters, "CheckboxWithImage", beside: "#GameList_View_SortByRecent", after: true),
        ClassRecipe(.filters, "Active", beside: "#GameList_View_SortByRecent", after: true, argument: 2),
    ]

    /// ``classRecipes`` as the JavaScript array the page's resolver reads.
    static let classRecipesLiteral: String = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(classRecipes) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }()
}
