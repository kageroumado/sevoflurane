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

    /// Steam's own program, read off the app overview in the client.
    /// 0 unknown, 1 unsupported, 2 playable, 3 verified.
    let deckCategory: Int?

    let mac: GameCompatBadge
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

    /// The Mac badge. Ordered so a structural failure always outranks a soft
    /// positive: anti-cheat first, then the wiki's Windows-build tiers, then
    /// the Linux prior, which can only ever say "playable, untested here".
    static func mac(
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        proton: GameCompatRecord.ProtonSummary?,
    ) -> GameCompatBadge {
        let blocker = antiCheatBlocker(antiCheat)
        let runsNatively: Set = ["perfect", "playable"]
        let hasNative = runsNatively.contains(wiki?.native ?? "") || runsNatively.contains(wiki?.rosetta2 ?? "")
        let nativeNote = hasNative ? " It also has a native Mac version." : ""
        if let wiki, let evidence = wikiEvidence(wiki) {
            switch evidence.tier {
            case "unplayable", "menu":
                return GameCompatBadge(
                    state: .unsupported, label: "Unsupported",
                    reason: "AppleGamingWiki rates \(evidence.method) \(describe(evidence.tier)).\(nativeNote)",
                )
            case "perfect" where blocker == nil:
                return GameCompatBadge(
                    state: .verified, label: "Verified",
                    reason: "AppleGamingWiki rates \(evidence.method) perfect.\(nativeNote)",
                )
            default:
                // Real Mac evidence outranks the anti-cheat veto, but never
                // past Playable: the game starts, its protected modes do not.
                let caveat = blocker == nil ? "" : " Online play stays blocked. See Anti-cheat."
                return GameCompatBadge(
                    state: .playable, label: "Playable",
                    reason: "AppleGamingWiki rates \(evidence.method) \(describe(evidence.tier)).\(caveat)\(nativeNote)",
                )
            }
        }
        if let blocker {
            return GameCompatBadge(
                state: .unsupported, label: "Unsupported",
                reason: "\(blocker) has no macOS module. The game will not start here.\(nativeNote)",
            )
        }
        if let proton, proton.confidence != "inadequate", proton.tier != "pending" {
            let count = proton.total.formatted()
            switch proton.tier {
            case "platinum", "gold":
                return GameCompatBadge(
                    state: .playable, label: "Playable",
                    reason: "Untested on a Mac. Runs well under Proton on Linux. ProtonDB rates it \(proton.tier) across \(count) reports.\(nativeNote)",
                )
            case "borked":
                return GameCompatBadge(
                    state: .unknown, label: "Unknown",
                    reason: "Untested on a Mac. Broken under Proton on Linux. ProtonDB rates it borked across \(count) reports.\(nativeNote)",
                )
            default:
                return GameCompatBadge(
                    state: .unknown, label: "Unknown",
                    reason: "Untested on a Mac. Mixed results under Proton on Linux. ProtonDB rates it \(proton.tier) across \(count) reports.\(nativeNote)",
                )
            }
        }
        return GameCompatBadge(
            state: .unknown, label: "Unknown",
            reason: "No Mac reports yet.\(nativeNote)",
        )
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

    /// The wiki's verdict on the Windows build, CrossOver's column first
    /// because it is the better populated: 483 perfect ratings to Wine's 171.
    /// A column that says nothing (`na`, `unknown`, absent) yields to the other.
    static func wikiEvidence(_ wiki: GameCompatRecord.WikiTiers) -> (method: String, tier: String)? {
        let rated: Set = ["perfect", "playable", "runs", "menu", "unplayable"]
        let crossover = wiki.crossover.flatMap { rated.contains($0) ? $0 : nil }
        let wine = wiki.wine.flatMap { rated.contains($0) ? $0 : nil }
        // A hard failure in either column outranks a pass in the other.
        for (method, tier) in [("CrossOver", crossover), ("Wine", wine)] {
            if let tier, tier == "unplayable" || tier == "menu" { return (method, tier) }
        }
        if let crossover { return ("CrossOver", crossover) }
        if let wine { return ("Wine", wine) }
        return nil
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
                guard let page = row["Page"] as? String, !page.isEmpty else { continue }
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
