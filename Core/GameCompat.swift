import Foundation

/// What the community databases say about one game running under the
/// bottle, kept per source so the headline badges can be explained.
///
/// Every field carries the source it came from, because the badges are
/// derived and a user who disagrees with one needs somewhere to go and look.
nonisolated struct GameCompatRecord: Codable, Sendable, Equatable {
    let appID: Int
    let name: String

    /// One AreWeAntiCheatYet entry. Its status describes Linux; the badge
    /// only ever reads the engine names and the vendor's outright refusals.
    struct AntiCheat: Codable, Sendable, Equatable {
        let engines: [String]
        /// `Broken`, `Running`, `Supported`, `Denied`, or `Planned`.
        let status: String
        let notes: [String]
        let sourceURL: URL
    }

    let antiCheat: AntiCheat?

    /// AppleGamingWiki's `Compatibility_macOS` row, lowercased and filtered
    /// to the wiki's own vocabulary: `perfect`, `playable`, `runs`, `menu`,
    /// `unplayable`, `na`, `unknown`.
    struct WikiTiers: Codable, Sendable, Equatable {
        let native: String?
        let rosetta2: String?
        let crossover: String?
        let wine: String?
        let parallels: String?
        let pageURL: URL
    }

    let wiki: WikiTiers?

    /// ProtonDB's summary for the app: a Linux measurement, shown as one and
    /// never promoted to a Mac verdict.
    struct ProtonSummary: Codable, Sendable, Equatable {
        let tier: String
        let confidence: String
        let total: Int
        let sourceURL: URL
    }

    let proton: ProtonSummary?

    /// Sevoflurane's own community database: runs players shared from this
    /// app, summarized by kagerou.glass. Its verdict is in the wiki's words
    /// and stays `unknown` until enough runs back it.
    struct Community: Codable, Sendable, Equatable {
        let verdict: String
        let runs: Int
        let installs: Int
        let engine: String?
        /// The median frame rate across installs, when runs measured one.
        let medianFPS: Double?
        let pageURL: URL
    }

    let community: Community?

    /// Whether Steam lists a macOS build of the game (`common/oslist` in the
    /// client's app cache).
    let hasMacBuild: Bool

    /// Which processors the macOS build is compiled for, from PCGamingWiki's
    /// `API` template: Steam's own cache leaves the architecture blank for
    /// most Mac builds. `nil` for a value the wiki leaves unknown.
    struct MacArchitectures: Codable, Sendable, Equatable {
        let intel32: Bool?
        let intel64: Bool?
        let arm: Bool?
        /// The PCGamingWiki page the fields were read from.
        var pageURL: URL?

        /// A build no Apple silicon Mac can run: Rosetta 2 translates 64-bit
        /// Intel code only, and macOS dropped 32-bit apps in 10.15.
        var is32BitOnly: Bool {
            intel32 == true && intel64 != true && arm != true
        }
    }

    let macArchitectures: MacArchitectures?

    /// Steam's own program, read off the app overview in the client.
    /// 0 unknown, 1 unsupported, 2 playable, 3 verified.
    let deckCategory: Int?

    let mac: GameCompatBadge
    /// The game's own macOS build, judged apart from the Windows build the
    /// bottle runs; `nil` when the game has none anyone knows of.
    let nativeBadge: GameCompatBadge?
    let antiCheatBadge: GameCompatBadge
    let fetchedAt: Date
}

/// One headline badge: a state drawn with Steam's own glyphs, and the line
/// that names the source behind it.
nonisolated struct GameCompatBadge: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case verified
        case playable
        case unsupported
        case unknown
    }

    let state: State
    let label: String
    let reason: String
}

/// One game's verdict as the library draws it: the Mac badge's state and
/// whether the game's own macOS build plays, without the reasons. The
/// library asks for hundreds at once; the game page asks for the whole
/// ``GameCompatRecord``.
nonisolated struct GameCompatSummary: Codable, Sendable, Equatable {
    let appID: Int
    let state: GameCompatBadge.State
    /// The wiki rates the macOS build perfect or playable.
    let native: Bool

    /// Whether the game belongs under the library's "Plays on Mac" filter:
    /// the Windows build is Verified or Playable, or the macOS build plays.
    var playsOnMac: Bool {
        native || state == .verified || state == .playable
    }
}

/// Why installing a game deserves a second thought, from the same verdicts
/// the strip shows.
nonisolated enum GameCompatInstallRisk: Equatable, Sendable {
    /// Anti-cheat that cannot run here: a kernel engine, or one AreWeAntiCheatYet
    /// lists as Denied or Broken. Carries the anti-cheat badge's reason and
    /// whether the game itself is known to start.
    case antiCheat(reason: String, gameStarts: Bool)
    /// The Mac verdict is Unsupported: a crash in Sevoflurane players' runs or
    /// on the wiki, or broken under Proton with nothing better known.
    case unsupported(reason: String)
}

/// The rules that turn the sources into the two badges.
nonisolated enum GameCompatVerdict {
    /// Anti-cheat that lives in a kernel driver, so no translation layer can
    /// carry it: a game that requires one refuses to start under the bottle
    /// no matter what the renderer does.
    static let kernelEngines: Set<String> = [
        "easy anti-cheat", "battleye", "vanguard", "nprotect gameguard",
        "xigncode3", "anti-cheat expert", "netease anti-cheat expert",
        "denuvo anti-cheat", "ricochet", "ea anticheat", "faceit",
        "neac protect", "treyarch anti-cheat", "equ8", "anybrain",
        "fredaikis anti-cheat", "punkbuster", "x-trap", "tenprotect",
        "ahnlab hackshield", "nexon game security", "sard", "arkos",
        "esl wire", "mail.ru anti-cheat", "my.games anti-cheat",
        "netease game security", "seasun protect", "wfsdrv",
    ]

    static func isKernel(_ engine: String) -> Bool {
        kernelEngines.contains(engine.lowercased())
    }

    /// The anti-cheat badge. Kernel engines and vendor refusals are
    /// unsupported outright; a user-mode engine the Linux community runs is
    /// playable; anything else is said plainly.
    static func antiCheat(_ record: GameCompatRecord.AntiCheat?) -> GameCompatBadge {
        guard let record else {
            return GameCompatBadge(
                state: .unknown, label: "None known",
                reason: "No anti-cheat is listed for this game on AreWeAntiCheatYet.",
            )
        }
        let engines = record.engines.joined(separator: ", ")
        if let kernel = record.engines.first(where: isKernel) {
            return GameCompatBadge(
                state: .unsupported, label: kernel,
                reason: "\(kernel) is kernel-mode anti-cheat with no macOS module. It usually guards online play, which cannot run here.",
            )
        }
        switch record.status {
        case "Denied":
            return GameCompatBadge(
                state: .unsupported, label: engines,
                reason: "The publisher refuses to run \(engines) outside Windows. AreWeAntiCheatYet lists it as Denied.",
            )
        case "Broken":
            return GameCompatBadge(
                state: .unsupported, label: engines,
                reason: "\(engines) breaks the game under Wine on Linux. Expect the same here. AreWeAntiCheatYet lists it as Broken.",
            )
        case "Supported", "Running":
            return GameCompatBadge(
                state: .playable, label: engines,
                reason: "\(engines) runs under Wine on Linux. User-mode anti-cheat usually works here too. AreWeAntiCheatYet lists it as \(record.status).",
            )
        default:
            return GameCompatBadge(
                state: .unknown, label: engines,
                reason: "AreWeAntiCheatYet lists \(engines) as \(record.status), with no verdict yet.",
            )
        }
    }

    /// The Mac badge for the Windows build the bottle runs. Sevoflurane's own
    /// runs come first, being this engine on real Macs; then a structural
    /// anti-cheat failure; then the wiki's Wine-family columns; then the
    /// Linux prior, which can only ever say "untested here".
    static func mac(
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        proton: GameCompatRecord.ProtonSummary?,
        community: GameCompatRecord.Community? = nil,
    ) -> GameCompatBadge {
        let blocker = antiCheatBlocker(antiCheat)
        let caveat = blocker == nil ? "" : " Online play stays blocked. See Anti-cheat."
        if let community, rank(community.verdict) != nil {
            let source = "Sevoflurane players rate it \(describe(community.verdict)) across "
                + "\(community.runs.formatted()) runs on \(macs(community.installs))."
            return badge(tier: community.verdict, blocker: blocker, reason: source, caveat: caveat)
        }
        if let wiki, let evidence = wikiEvidence(wiki) {
            if evidence.capped {
                return GameCompatBadge(state: .playable, label: "Playable", reason: evidence.reason + caveat)
            }
            return badge(tier: evidence.tier, blocker: blocker, reason: evidence.reason, caveat: caveat)
        }
        if let blocker {
            return GameCompatBadge(
                state: .unsupported, label: "Unsupported",
                reason: "\(blocker) has no macOS module. The game will not start here.",
            )
        }
        if let proton, proton.confidence != "inadequate", proton.tier != "pending" {
            let source = "ProtonDB rates it \(proton.tier) across \(proton.total.formatted()) reports."
            switch proton.tier {
            case "platinum", "gold":
                return GameCompatBadge(
                    state: .playable, label: "Playable",
                    reason: "Untested on a Mac. Runs well under Proton on Linux. \(source)",
                )
            case "silver", "bronze":
                return GameCompatBadge(
                    state: .playable, label: "Playable",
                    reason: "Untested on a Mac. Runs with issues under Proton on Linux. \(source)",
                )
            case "borked":
                return GameCompatBadge(
                    state: .unsupported, label: "Unsupported",
                    reason: "Untested on a Mac. Broken under Proton on Linux. \(source)",
                )
            default:
                break
            }
        }
        return GameCompatBadge(state: .unknown, label: "Unknown", reason: "No Mac reports yet.")
    }

    /// The badge one tier earns: a crash is unsupported, perfect is verified
    /// unless anti-cheat blocks a mode, and anything that runs is playable.
    /// Real Mac evidence outranks the anti-cheat veto, but never past
    /// Playable: the game starts, its protected modes do not.
    private static func badge(tier: String, blocker: String?, reason: String, caveat: String) -> GameCompatBadge {
        switch tier {
        case "unplayable", "menu":
            GameCompatBadge(state: .unsupported, label: "Unsupported", reason: reason)
        case "perfect" where blocker == nil:
            GameCompatBadge(state: .verified, label: "Verified", reason: reason)
        default:
            GameCompatBadge(state: .playable, label: "Playable", reason: reason + caveat)
        }
    }

    /// The badge for the game's own macOS build, drawn beside the Windows
    /// verdict and independent of it. The wiki's native column speaks for
    /// the build, Rosetta 2's when native is unrated; a build Steam lists
    /// that nobody has rated reads as available. A 32-bit-only build gets no
    /// badge at all, whatever anyone rated it: no Apple silicon Mac runs it.
    static func native(
        wiki: GameCompatRecord.WikiTiers?, hasMacBuild: Bool,
        architectures: GameCompatRecord.MacArchitectures? = nil,
    ) -> GameCompatBadge? {
        if architectures?.is32BitOnly == true { return nil }
        let rated: (String, String)? = if let tier = wiki?.native, rank(tier) != nil {
            ("", tier)
        } else if let tier = wiki?.rosetta2, rank(tier) != nil {
            (" under Rosetta 2", tier)
        } else {
            nil
        }
        guard let (how, tier) = rated else {
            guard hasMacBuild else { return nil }
            return GameCompatBadge(
                state: .unknown, label: "Available",
                reason: "Steam lists a macOS version. Steam for Mac runs it directly, outside the bottle.",
            )
        }
        let reason = "AppleGamingWiki rates the macOS version \(describe(tier))\(how)."
        return switch tier {
        case "unplayable", "menu":
            GameCompatBadge(state: .unsupported, label: "Broken", reason: reason)
        case "perfect":
            GameCompatBadge(state: .verified, label: "Perfect", reason: reason)
        default:
            GameCompatBadge(state: .playable, label: "Playable", reason: reason)
        }
    }

    /// The library's verdict, from the same rules as the strip's badges.
    static func summary(
        appID: Int,
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        proton: GameCompatRecord.ProtonSummary?,
        community: GameCompatRecord.Community?,
        hasMacBuild: Bool,
        architectures: GameCompatRecord.MacArchitectures?,
    ) -> GameCompatSummary {
        let native = native(wiki: wiki, hasMacBuild: hasMacBuild, architectures: architectures)
        return GameCompatSummary(
            appID: appID,
            state: mac(antiCheat: antiCheat, wiki: wiki, proton: proton, community: community).state,
            native: native?.state == .verified || native?.state == .playable,
        )
    }

    /// What installing the Windows build risks, or `nil` when nothing known
    /// stands in its way. Anti-cheat speaks first, being the failure no
    /// setting fixes.
    static func installRisk(_ record: GameCompatRecord) -> GameCompatInstallRisk? {
        if record.antiCheatBadge.state == .unsupported {
            return .antiCheat(reason: record.antiCheatBadge.reason, gameStarts: record.mac.state != .unsupported)
        }
        if record.mac.state == .unsupported { return .unsupported(reason: record.mac.reason) }
        return nil
    }

    /// The anti-cheat that stops the game outright, named for the reason
    /// line: a kernel engine, or a publisher who said no outside Windows.
    static func antiCheatBlocker(_ antiCheat: GameCompatRecord.AntiCheat?) -> String? {
        guard let antiCheat else { return nil }
        if let kernel = antiCheat.engines.first(where: isKernel) { return "\(kernel) kernel anti-cheat" }
        if antiCheat.status == "Denied" {
            return "\(antiCheat.engines.joined(separator: ", ")) anti-cheat (declined by the publisher outside Windows)"
        }
        return nil
    }

    /// The wiki's verdict on the Windows build from its two Wine-family
    /// columns. One rated column, or two that agree, give their tier. Two
    /// that disagree give the better one capped at Playable when it is a
    /// pass: a pass under one Wine on a Mac shows the build can run, and the
    /// other column's failure is the reason to withhold Verified.
    static func wikiEvidence(_ wiki: GameCompatRecord.WikiTiers) -> (tier: String, capped: Bool, reason: String)? {
        let crossover = wiki.crossover.flatMap { rank($0) != nil ? $0 : nil }
        let wine = wiki.wine.flatMap { rank($0) != nil ? $0 : nil }
        switch (wine, crossover) {
        case let (wine?, crossover?) where wine != crossover:
            let better = rank(wine)! > rank(crossover)! ? wine : crossover
            let reason = "AppleGamingWiki rates Wine \(describe(wine)) and CrossOver \(describe(crossover))."
            return (better, rank(better)! >= rank("runs")!, reason)
        case let (wine?, crossover):
            let both = crossover == nil ? "Wine" : "Wine and CrossOver"
            return (wine, false, "AppleGamingWiki rates \(both) \(describe(wine)).")
        case let (nil, crossover?):
            return (crossover, false, "AppleGamingWiki rates CrossOver \(describe(crossover)).")
        case (nil, nil):
            return nil
        }
    }

    /// The wiki's rated tiers, worst to best; `na`, `unknown` and anything
    /// else rank as no rating.
    static func rank(_ tier: String) -> Int? {
        ["unplayable", "menu", "runs", "playable", "perfect"].firstIndex(of: tier)
    }

    static func macs(_ count: Int) -> String {
        count == 1 ? "1 Mac" : "\(count.formatted()) Macs"
    }

    /// The wiki's tier words as they read in a sentence.
    static func describe(_ tier: String) -> String {
        switch tier {
        case "perfect": "perfect"
        case "playable": "playable, with minor glitches"
        case "runs": "as running, with major glitches"
        case "menu": "as crashing at the menu"
        case "unplayable": "as crashing at boot"
        default: tier
        }
    }
}

/// Title matching for the one source keyed on page names rather than app ids.
nonisolated enum GameCompatTitles {
    /// Folds a game title to the form two databases agree on: case, marks,
    /// `&` against `and`, punctuation, and a leading article.
    static func normalize(_ title: String) -> String {
        var text = title
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: "™", with: "")
            .replacingOccurrences(of: "®", with: "")
            .replacingOccurrences(of: "©", with: "")
            .folding(options: [.diacriticInsensitive, .caseInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
        text = text.replacingOccurrences(of: "[’'`]", with: "", options: .regularExpression)
        text = text.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("the ") { text = String(text.dropFirst(4)) }
        return text
    }
}

// MARK: - Source parsing

nonisolated enum GameCompatSources {
    static let antiCheatDataURL = URL(string: "https://raw.githubusercontent.com/AreWeAntiCheatYet/AreWeAntiCheatYet/HEAD/games.json")!
    static let antiCheatSiteURL = URL(string: "https://areweanticheatyet.com")!
    static let wikiExportURL = URL(string: "https://www.applegamingwiki.com/w/index.php?title=Special:CargoExport&tables=Compatibility_macOS&fields=_pageName%3DPage,native,rosetta_2,crossover,wine,parallels&limit=5000&format=json")!
    static let wikiPageBase = "https://www.applegamingwiki.com/wiki/"

    static func protonSummaryURL(appID: Int) -> URL {
        URL(string: "https://www.protondb.com/api/v1/reports/summaries/\(appID).json")!
    }

    static func protonPageURL(appID: Int) -> URL {
        URL(string: "https://www.protondb.com/app/\(appID)")!
    }

    static func pcGamingWikiLookupURL(appID: Int) -> URL {
        URL(string: "https://www.pcgamingwiki.com/w/api.php?action=idlookup&format=json&field=steamappid&value=\(appID)&formatversion=2")!
    }

    /// AreWeAntiCheatYet's `games.json`, indexed by Steam app id where the
    /// record carries one and by normalized title as the fallback.
    struct AntiCheatIndex: Sendable {
        private let byAppID: [Int: GameCompatRecord.AntiCheat]
        private let byTitle: [String: GameCompatRecord.AntiCheat]

        /// Read by hand rather than decoded: `storeIds` mixes strings
        /// (`steam`) with objects (`epic`), and one odd record must not take
        /// the whole table with it.
        init(data: Data) throws {
            guard let entries = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw GameCompatError("AreWeAntiCheatYet games.json is not a JSON array")
            }
            var byAppID: [Int: GameCompatRecord.AntiCheat] = [:]
            var byTitle: [String: GameCompatRecord.AntiCheat] = [:]
            for entry in entries {
                guard let name = entry["name"] as? String, let status = entry["status"] as? String else { continue }
                let slug = entry["slug"] as? String
                let record = GameCompatRecord.AntiCheat(
                    engines: entry["anticheats"] as? [String] ?? [],
                    status: status,
                    notes: (entry["notes"] as? [[Any]] ?? []).compactMap { $0.first as? String },
                    sourceURL: slug.map { antiCheatSiteURL.appendingPathComponent("game/\($0)") } ?? antiCheatSiteURL,
                )
                if let steam = (entry["storeIds"] as? [String: Any])?["steam"] as? String, let appID = Int(steam) {
                    byAppID[appID] = record
                }
                let key = GameCompatTitles.normalize(name)
                if !key.isEmpty, byTitle[key] == nil { byTitle[key] = record }
            }
            self.byAppID = byAppID
            self.byTitle = byTitle
        }

        func lookup(appID: Int, name: String) -> GameCompatRecord.AntiCheat? {
            byAppID[appID] ?? byTitle[GameCompatTitles.normalize(name)]
        }
    }

    /// AppleGamingWiki's `Compatibility_macOS` table, indexed by normalized
    /// page title. The export's keys are display names with spaces
    /// (`"rosetta 2"`), so they are read by hand.
    struct WikiIndex: Sendable {
        static let vocabulary: Set<String> = [
            "perfect", "playable", "runs", "menu", "unplayable", "na", "unknown",
        ]

        private let byTitle: [String: GameCompatRecord.WikiTiers]

        init(data: Data) throws {
            guard let rows = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                throw GameCompatError("AppleGamingWiki export is not a JSON array")
            }
            var byTitle: [String: GameCompatRecord.WikiTiers] = [:]
            for row in rows {
                // A page titled with a number (`5`) arrives as a JSON number.
                guard let raw = row["Page"], !(raw is NSNull) else { continue }
                let page = "\(raw)"
                guard !page.isEmpty else { continue }
                let slug = page.replacingOccurrences(of: " ", with: "_")
                let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
                guard let pageURL = URL(string: wikiPageBase + encoded) else { continue }
                let tiers = GameCompatRecord.WikiTiers(
                    native: Self.tier(row["native"]),
                    rosetta2: Self.tier(row["rosetta 2"]),
                    crossover: Self.tier(row["crossover"]),
                    wine: Self.tier(row["wine"]),
                    parallels: Self.tier(row["parallels"]),
                    pageURL: pageURL,
                )
                let key = GameCompatTitles.normalize(page)
                if !key.isEmpty, byTitle[key] == nil { byTitle[key] = tiers }
            }
            self.byTitle = byTitle
        }

        /// One cell, lowercased and kept only when it is a word the wiki's
        /// rating template defines; strays and parser artifacts read as absent.
        static func tier(_ value: Any?) -> String? {
            guard let text = value as? String else { return nil }
            let word = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            return vocabulary.contains(word) ? word : nil
        }

        func lookup(title: String) -> GameCompatRecord.WikiTiers? {
            byTitle[GameCompatTitles.normalize(title)]
        }
    }

    /// One ProtonDB summary. A missing app answers 404 with an HTML page, so
    /// anything that is not the JSON shape reads as absent.
    static func protonSummary(appID: Int, data: Data) -> GameCompatRecord.ProtonSummary? {
        struct Summary: Decodable {
            let tier: String
            let confidence: String
            let total: Int
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return GameCompatRecord.ProtonSummary(
            tier: summary.tier,
            confidence: summary.confidence,
            total: summary.total,
            sourceURL: protonPageURL(appID: appID),
        )
    }

    /// One game's summary from Sevoflurane's community database
    /// (`GET /v1/games/<appid>`). A game with no runs answers 404, cached as
    /// `{}`, which reads as absent like anything else off the shape.
    static func community(data: Data) -> GameCompatRecord.Community? {
        struct Summary: Decodable {
            struct FPS: Decodable {
                let median_avg: Double
            }

            let verdict: String
            let runs: Int
            let installs: Int
            let engine: String?
            let fps: FPS?
            let url: URL
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return GameCompatRecord.Community(
            verdict: summary.verdict, runs: summary.runs, installs: summary.installs,
            engine: summary.engine, medianFPS: summary.fps?.median_avg, pageURL: summary.url,
        )
    }

    static func pcGamingWikiPageURL(title: String) -> URL? {
        let slug = title.replacingOccurrences(of: " ", with: "_")
        return URL(string: "https://www.pcgamingwiki.com/wiki/" + (slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug))
    }

    static func pcGamingWikiTextURL(title: String) -> URL? {
        var components = URLComponents(string: "https://www.pcgamingwiki.com/w/api.php")!
        components.queryItems = [
            URLQueryItem(name: "action", value: "parse"), URLQueryItem(name: "page", value: title),
            URLQueryItem(name: "prop", value: "wikitext"), URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "formatversion", value: "2"),
        ]
        return components.url
    }

    /// The macOS architectures in a PCGamingWiki page's `{{API` template:
    /// `|macos intel 32-bit app = true`, `|macos intel 64-bit app = false`,
    /// `|macos arm app = unknown`. `nil` when the page has no template or
    /// says nothing about any of the three.
    static func macArchitectures(wikitext: String) -> GameCompatRecord.MacArchitectures? {
        func field(_ name: String) -> Bool? {
            let pattern = #"(?m)^\|[ \t]*"# + NSRegularExpression.escapedPattern(for: name) + #"[ \t]*=[ \t]*(\w*)"#
            guard let match = wikitext.range(of: pattern, options: .regularExpression) else { return nil }
            let value = wikitext[match].split(separator: "=").last?.trimmingCharacters(in: .whitespaces).lowercased()
            return switch value {
            case "true": true
            case "false": false
            default: nil
            }
        }
        let architectures = GameCompatRecord.MacArchitectures(
            intel32: field("macos intel 32-bit app"), intel64: field("macos intel 64-bit app"),
            arm: field("macos arm app"), pageURL: nil,
        )
        return architectures.intel32 == nil && architectures.intel64 == nil && architectures.arm == nil
            ? nil : architectures
    }

    /// The wikitext out of PCGamingWiki's `action=parse` answer.
    static func pcGamingWikiText(data: Data) -> String? {
        struct Parse: Decodable {
            struct Page: Decodable {
                let wikitext: String
            }

            let parse: Page
        }
        return (try? JSONDecoder().decode(Parse.self, from: data))?.parse.wikitext
    }

    /// PCGamingWiki's page title for a Steam app id, the bridge to a wiki
    /// keyed on titles when Steam's own display name does not match.
    static func pcGamingWikiTitle(data: Data) -> String? {
        struct Lookup: Decodable {
            struct Hit: Decodable {
                struct Title: Decodable {
                    let Page: String
                }

                let title: Title
            }

            let idlookup: [Hit]
        }
        return (try? JSONDecoder().decode(Lookup.self, from: data))?.idlookup.first?.title.Page
    }
}

nonisolated struct GameCompatError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) {
        self.description = description
    }
}
