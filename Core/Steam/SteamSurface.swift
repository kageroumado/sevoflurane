import Foundation

/// Everything the app depends on inside Steam's client, in one list.
///
/// Steam ships a new client every few weeks and promises nothing about its
/// insides: the `SteamClient` bindings, the stores its pages keep on `window`,
/// the names its minifier leaves, its class names and popup names. Each
/// ``Entry`` names one of those, says what the app uses it for, and carries a
/// ``Probe`` that a client's `steamui` files answer with found, missing or
/// changed (``audit(_:entries:)``, `sevo steam audit`), with no client
/// running.
///
/// The app's Swift takes these names from here. The injected JavaScript
/// spells them out, and `SteamSurfaceDriftTests` holds the two together: a
/// Steam internal the sources use and this list lacks fails it, and so does
/// an entry nothing uses.
nonisolated enum SteamSurface {
    /// What sort of thing an entry depends on.
    enum Kind: String, CaseIterable, Codable, Sendable {
        /// A `SteamClient` method the app calls.
        case call
        /// A surface the app answers in the client's place, which Steam's
        /// pages call into.
        case answered
        /// An object Steam's page keeps on `window`.
        case global
        /// A property or method of one of Steam's objects.
        case member
        /// A CSS-module class map, found through webpack by its keys.
        case classMap
        /// Text by which a webpack module is found.
        case marker
        /// A class name Steam's markup carries unhashed.
        case cssClass
        /// The name Steam opens a popup under.
        case windowName
        /// A `steam://` command or a route inside the UI.
        case url
        /// A message or event name passed between Steam's page and its host.
        case message
        /// A client setting's key.
        case setting
        /// A fixed value of Steam's protocol with the client.
        case constant
        /// Markup of Steam's store and community web pages.
        case webPage
    }

    /// One dependency.
    struct Entry: Sendable, Equatable {
        let kind: Kind
        /// The name as Steam spells it.
        let name: String
        /// What the app uses it for.
        let use: String
        let probe: Probe
        /// Every spelling of the entry in the app's sources: the name itself,
        /// or for a class map its keys.
        let tokens: [String]

        init(_ kind: Kind, _ name: String, _ use: String, _ probe: Probe, tokens: [String]? = nil) {
            self.kind = kind
            self.name = name
            self.use = use
            self.probe = probe
            self.tokens = tokens ?? [name]
        }
    }

    /// How a client's files answer for an entry.
    enum Probe: Sendable, Equatable {
        /// `SteamClient.<path>(…)` in Steam's own code. `passes` is the
        /// number of arguments the app's calls pass, nil for a call the app
        /// only routes or listens in on; the client refuses a call with fewer
        /// than its own code passes. `steamCalls` says Steam's UI called the
        /// method when the entry was written, so its absence means the method
        /// went away. `handler` holds the parameter counts of Steam's own
        /// callbacks, for a registration whose arguments the app reads by
        /// position.
        case call(passes: Int?, steamCalls: Bool, handler: [Int]?)
        /// An assignment to `window.<name>`.
        case global
        /// The name, standing alone. With `passes`, a definition that takes
        /// that many arguments.
        case identifier(passes: Int?)
        /// A class map holding every `signature` key, in a module no longer
        /// than `limit` characters, with every one of the entry's tokens.
        case classMap(signature: [String], limit: Int)
        /// Every one of these texts, somewhere in the scripts.
        case text([String])
        /// The class, in a style sheet or a script.
        case cssClass
        /// The calls Steam's code makes into a surface the app answers.
        case supplied(Supplied)
        /// Calls to Chromium-only APIs (``ChromiumSurface``).
        case chromium
        /// The client's files cannot answer; the reason.
        case unchecked(String)
    }

    /// A surface the app answers, and how Steam's calls into it are found.
    struct Supplied: Sendable, Equatable {
        enum Shape: Sendable, Equatable {
            /// `<namespace>.<Method>(`.
            case namespace(String)
            /// `<receiver>.<Method>(` for each receiver, a field name Steam's
            /// classes keep the object in.
            case receivers([String])
            /// `.on("<event>",`.
            case listeners
        }

        let shape: Shape
        /// What the app answers.
        let answered: [String]
        /// What Steam calls and the app deliberately leaves unanswered.
        let ignored: [String]
    }

    /// The whole list.
    static let catalog: [Entry] = calls + answeredSurfaces + globals + members + classMaps + markers
        + cssClasses + windowNames + urls + messages + settings + constants + webPages

    /// The entries of one kind.
    static func entries(of kind: Kind) -> [Entry] {
        catalog.filter { $0.kind == kind }
    }
}
