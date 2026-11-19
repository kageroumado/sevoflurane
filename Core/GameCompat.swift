import Foundation

/// What the community databases say about one game, kept per source with
/// its URL so each derived badge can be explained.
nonisolated struct GameCompatRecord: Codable, Sendable, Equatable {
    let appID: Int
    let name: String

    /// One AreWeAntiCheatYet entry. Its status describes Linux.
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

    /// Sevoflurane's community database, summarized by kagerou.glass; the
    /// verdict uses the wiki's words and stays `unknown` until enough runs
    /// back it.
    struct Community: Codable, Sendable, Equatable {
        let verdict: String
        let runs: Int
        let installs: Int
        let engine: String?
        /// The median frame rate across installs, when runs measured one.
        let medianFPS: Double?
        let pageURL: URL
        /// The runs the verdict leaves out: the ones a tool stopped.
        var leftOut = 0
        // Shares (0–1), each the median across installs.
        /// Runs that drew a frame, over the judged runs plus the left-out
        /// ones that drew.
        var reachedFrame: Double? = nil
        /// Judged runs played past five minutes and ended by the player.
        var played: Double? = nil
        /// Judged runs that crashed.
        var crashed: Double? = nil

        /// The runs the verdict is taken over.
        var judged: Int {
            max(runs - leftOut, 0)
        }
    }

    let community: Community?

    /// Whether Steam lists a macOS build of the game (`common/oslist` in the
    /// client's app cache).
    let hasMacBuild: Bool

    /// The macOS build's architectures, from PCGamingWiki's `API` template
    /// (Steam's cache leaves them blank); `nil` where the wiki says unknown.
    struct MacArchitectures: Codable, Sendable, Equatable {
        let intel32: Bool?
        let intel64: Bool?
        let arm: Bool?
        /// The PCGamingWiki page the fields were read from.
        var pageURL: URL?

        /// A build no Apple silicon Mac can run: Rosetta 2 is 64-bit only.
        var is32BitOnly: Bool {
            intel32 == true && intel64 != true && arm != true
        }
    }

    let macArchitectures: MacArchitectures?

    /// Steam's own program, read off the app overview in the client.
    /// 0 unknown, 1 unsupported, 2 playable, 3 verified.
    let deckCategory: Int?

    let mac: GameCompatBadge
    /// The game's own macOS build; `nil` when none is known.
    let nativeBadge: GameCompatBadge?
    let antiCheatBadge: GameCompatBadge
    let fetchedAt: Date
    /// Set for an app that serves a Mac through a partner app (``GameCompanion``).
    var companion: GameCompanion? = nil

    /// A companion app's record: Verified through its partner.
    static func companion(_ companion: GameCompanion, name: String, deckCategory: Int?) -> GameCompatRecord {
        GameCompatRecord(
            appID: companion.appID, name: name.isEmpty ? companion.name : name,
            antiCheat: nil, wiki: nil, proton: nil, community: nil, hasMacBuild: false, macArchitectures: nil,
            deckCategory: deckCategory,
            mac: GameCompatVerdict.companion(companion), nativeBadge: nil,
            antiCheatBadge: GameCompatVerdict.antiCheat(nil), fetchedAt: .now, companion: companion,
        )
    }
}

/// One headline badge: the state the app's rules read, the reason naming its
/// source, and a rated build's tier on ProtonDB's medal scale.
nonisolated struct GameCompatBadge: Codable, Sendable, Equatable {
    enum State: String, Codable, Sendable {
        case verified
        case playable
        case unsupported
        case unknown
    }

    /// ProtonDB's five tiers. Wiki words map by meaning: `perfect` Platinum,
    /// `playable` Silver, `runs` Bronze, `menu` and `unplayable` Borked; only
    /// ProtonDB awards Gold.
    enum Tier: String, Codable, Sendable, CaseIterable {
        case platinum
        case gold
        case silver
        case bronze
        case borked

        var label: String { rawValue.capitalized }

        /// Only Platinum is Verified, and only Borked fails.
        var state: State {
            switch self {
            case .platinum: .verified
            case .gold, .silver, .bronze: .playable
            case .borked: .unsupported
            }
        }

        /// `nil` for an unrated word.
        init?(wiki word: String) {
            switch word {
            case "perfect": self = .platinum
            case "playable": self = .silver
            case "runs": self = .bronze
            case "menu", "unplayable": self = .borked
            default: return nil
            }
        }

        /// `nil` for `pending` and anything else.
        init?(proton word: String) {
            self.init(rawValue: word)
        }

        /// The cases run best first.
        func isBetter(than other: Tier) -> Bool {
            Self.allCases.firstIndex(of: self)! < Self.allCases.firstIndex(of: other)!
        }
    }

    let state: State
    let label: String
    let reason: String
    var tier: Tier? = nil

    init(state: State, label: String, reason: String, tier: Tier? = nil) {
        self.state = state
        self.label = label
        self.reason = reason
        self.tier = tier
    }

    init(tier: Tier, reason: String) {
        self.init(state: tier.state, label: tier.label, reason: reason, tier: tier)
    }
}

/// One game's verdict for the library grid, without the reasons; the game
/// page reads the whole ``GameCompatRecord``.
nonisolated struct GameCompatSummary: Codable, Sendable, Equatable {
    let appID: Int
    let state: GameCompatBadge.State
    /// The wiki rates the macOS build perfect or playable.
    let native: Bool
    /// The macOS build runs on Apple silicon: rated playable, or unrated with
    /// PCGamingWiki naming a 64-bit Intel or arm64 slice, since many listed
    /// builds are 32-bit only.
    var macRunnable = false
    /// The Windows verdict comes from Sevoflurane players' runs or
    /// AppleGamingWiki.
    var macEvidence = false
    var tier: GameCompatBadge.Tier? = nil
    /// The Windows verdict rests on ProtonDB alone.
    var linuxOnly = false
    /// The partner app a companion plays through (``GameCompanion``).
    var companion: String? = nil

    /// Whether the game belongs under the library's Apple filter.
    var playsOnMac: Bool {
        native || macRunnable || (macEvidence && (state == .verified || state == .playable))
    }
}

/// Why installing a game deserves a second thought.
nonisolated enum GameCompatInstallRisk: Equatable, Sendable {
    /// The anti-cheat badge is Unsupported.
    case antiCheat(reason: String, gameStarts: Bool)
    /// The Mac verdict is Unsupported.
    case unsupported(reason: String)
}

/// The rules that turn the sources into the two badges.
nonisolated enum GameCompatVerdict {
    /// Kernel-driver anti-cheat, which no translation layer can carry.
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

    /// Kernel engines and vendor refusals are unsupported; a user-mode engine
    /// that runs on Linux is playable.
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

    /// The Mac badge for the Windows build, by precedence: Sevoflurane
    /// players' runs (a single Mac rating below the wiki gives the wiki's
    /// tier capped at Silver), an anti-cheat blocker, the wiki's columns, then
    /// ProtonDB, whose state stops at Playable.
    static func mac(
        antiCheat: GameCompatRecord.AntiCheat?,
        wiki: GameCompatRecord.WikiTiers?,
        proton: GameCompatRecord.ProtonSummary?,
        community: GameCompatRecord.Community? = nil,
    ) -> GameCompatBadge {
        let blocker = antiCheatBlocker(antiCheat)
        let caveat = blocker == nil ? "" : " Online play stays blocked. See Anti-cheat."
        if let community, let players = GameCompatBadge.Tier(wiki: community.verdict) {
            if community.installs == 1, let wiki, let evidence = wikiEvidence(wiki),
               let rated = GameCompatBadge.Tier(wiki: evidence.tier), rated.isBetter(than: players) {
                let capped = rank(evidence.tier)! > rank("playable")! ? "playable" : evidence.tier
                let reason = evidence.reason + " " + describe(community)
                return badge(tier: capped, blocker: blocker, reason: reason, caveat: caveat)
            }
            return badge(tier: community.verdict, blocker: blocker, reason: describe(community), caveat: caveat)
        }
        if let wiki, let evidence = wikiEvidence(wiki) {
            if evidence.capped {
                return GameCompatBadge(tier: .silver, reason: evidence.reason + caveat)
            }
            return badge(tier: evidence.tier, blocker: blocker, reason: evidence.reason, caveat: caveat)
        }
        if let blocker {
            return GameCompatBadge(
                tier: .borked,
                reason: "\(blocker) has no macOS module. The game will not start here.",
            )
        }
        if let proton, proton.confidence != "inadequate", let tier = GameCompatBadge.Tier(proton: proton.tier) {
            let source = "ProtonDB rates it \(tier.label) across \(proton.total.formatted()) reports."
            let how = switch tier {
            case .platinum, .gold: "Runs well under Proton on Linux."
            case .silver, .bronze: "Runs with issues under Proton on Linux."
            case .borked: "Broken under Proton on Linux."
            }
            // The medal is ProtonDB's; the state is never Verified on Linux evidence alone.
            return GameCompatBadge(
                state: tier == .borked ? .unsupported : .playable, label: tier.label,
                reason: "Untested on a Mac. \(how) \(source)", tier: tier,
            )
        }
        return GameCompatBadge(state: .unknown, label: "Unknown", reason: "No Mac reports yet.")
    }

    /// The badge one wiki word earns; with an anti-cheat blocker Platinum
    /// drops to Silver, and an unrated word reads as Silver.
    private static func badge(tier word: String, blocker: String?, reason: String, caveat: String) -> GameCompatBadge {
        let tier = GameCompatBadge.Tier(wiki: word) ?? .silver
        switch tier {
        case .borked:
            return GameCompatBadge(tier: .borked, reason: reason)
        case .platinum where blocker == nil:
            return GameCompatBadge(tier: .platinum, reason: reason)
        case .platinum:
            return GameCompatBadge(tier: .silver, reason: reason + caveat)
        default:
            return GameCompatBadge(tier: tier, reason: reason + caveat)
        }
    }

    /// The badge for the game's own macOS build: the wiki's native column,
    /// else its Rosetta 2 column, else "Available" when Steam lists one. A
    /// 32-bit-only build gets none.
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
                reason: "Steam lists a macOS version.",
            )
        }
        let reason = "AppleGamingWiki rates the macOS version \(describe(tier))\(how)."
        return GameCompatBadge(state: nativeState(tier), label: nativeLabel(tier), reason: reason)
    }

    /// The badge of a companion app: Verified, through the partner that uses
    /// what Steam downloads.
    static func companion(_ companion: GameCompanion) -> GameCompatBadge {
        GameCompatBadge(state: .verified, label: "Through \(companion.partner)", reason: companion.reason)
    }

    /// The library's verdict for a companion app: it plays on this Mac, by
    /// Mac evidence, through its partner.
    static func summary(companion: GameCompanion, appID: Int) -> GameCompatSummary {
        GameCompatSummary(appID: appID, state: .verified, native: false, macEvidence: true, companion: companion.partner)
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
        let communityRated = community.map { rank($0.verdict) != nil } ?? false
        let wikiRated = wiki.map { wikiEvidence($0) != nil } ?? false
        let mac = mac(antiCheat: antiCheat, wiki: wiki, proton: proton, community: community)
        return GameCompatSummary(
            appID: appID,
            state: mac.state,
            native: native?.state == .verified || native?.state == .playable,
            macRunnable: native.map { badge in
                badge.state == .verified || badge.state == .playable
                    || (badge.state == .unknown && (architectures?.intel64 == true || architectures?.arm == true))
            } ?? false,
            macEvidence: communityRated || wikiRated,
            tier: mac.tier,
            linuxOnly: mac.state != .unknown && !communityRated && !wikiRated && antiCheatBlocker(antiCheat) == nil,
        )
    }

    /// What installing risks, anti-cheat first since no setting fixes it.
    static func installRisk(_ record: GameCompatRecord) -> GameCompatInstallRisk? {
        if record.antiCheatBadge.state == .unsupported {
            return .antiCheat(reason: record.antiCheatBadge.reason, gameStarts: record.mac.state != .unsupported)
        }
        if record.mac.state == .unsupported { return .unsupported(reason: record.mac.reason) }
        return nil
    }

    /// A kernel engine or a publisher's refusal, named for the reason line.
    static func antiCheatBlocker(_ antiCheat: GameCompatRecord.AntiCheat?) -> String? {
        guard let antiCheat else { return nil }
        if let kernel = antiCheat.engines.first(where: isKernel) { return "\(kernel) kernel anti-cheat" }
        if antiCheat.status == "Denied" {
            return "\(antiCheat.engines.joined(separator: ", ")) anti-cheat (declined by the publisher outside Windows)"
        }
        return nil
    }

    /// The wiki's verdict from its Wine and CrossOver columns. Two that
    /// disagree give the better one, flagged `capped` when it is a pass.
    static func wikiEvidence(_ wiki: GameCompatRecord.WikiTiers) -> (tier: String, capped: Bool, reason: String)? {
        let crossover = wiki.crossover.flatMap { rank($0) != nil ? $0 : nil }
        let wine = wiki.wine.flatMap { rank($0) != nil ? $0 : nil }
        switch (wine, crossover) {
        case let (wine?, crossover?) where wine != crossover:
            let better = rank(wine)! > rank(crossover)! ? wine : crossover
            let first = describe(wine)
            let joint = first.contains(",") ? ", and" : " and"
            let reason = "AppleGamingWiki rates Wine \(first)\(joint) CrossOver \(describe(crossover))."
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

    static func runs(_ count: Int) -> String {
        count == 1 ? "1 run" : "\(count.formatted()) runs"
    }

    /// What Sevoflurane players' runs show. One Mac's shares are told as run
    /// counts; across several, each is the median Mac's.
    static func describe(_ community: GameCompatRecord.Community) -> String {
        let one = community.installs == 1
        let tally = "\(runs(community.judged)) on \(macs(community.installs))"
        let typical = one ? "" : " on a typical Mac"
        /// The judged runs a share stands for, when it is one Mac's.
        func count(_ share: Double?) -> Int? {
            guard one, let share else { return nil }
            return Int((share * Double(community.judged)).rounded())
        }
        let played = "played past five minutes and ended by the player"
        let finding: String? = switch community.verdict {
        case "unplayable", "menu":
            // A run count only when none was left out (see `reachedFrame`).
            if community.leftOut == 0, let drew = count(community.reachedFrame) {
                drew == 0 ? "it reached no frame in \(tally)" : "it reached a frame in \(drew) of \(tally)"
            } else if community.reachedFrame != nil {
                "it reached a frame in fewer than half the runs\(typical), across \(tally)"
            } else {
                nil
            }
        case "runs":
            if let share = community.played, share < 0.5 {
                if let kept = count(share) {
                    kept == 0 ? "it starts, but none of \(tally) was \(played)"
                        : "it starts, but only \(kept) of \(tally) \(kept == 1 ? "was" : "were") \(played)"
                } else {
                    "it starts, but fewer than half the runs\(typical) were \(played), across \(tally)"
                }
            } else if let share = community.crashed, share > 0.1 {
                if let crashes = count(share) {
                    "it plays, but \(crashes) of \(tally) crashed"
                } else {
                    "it plays, but more than one run in ten\(typical) crashed, across \(tally)"
                }
            } else {
                nil
            }
        case "playable": "playable across \(tally)"
        case "perfect": "perfect across \(tally)"
        default: nil
        }
        if let finding { return "Sevoflurane players: \(finding)." }
        let tier = GameCompatBadge.Tier(wiki: community.verdict)?.label ?? community.verdict
        return "Sevoflurane players rate it \(tier) across \(tally)."
    }

    /// A macOS version keeps AppleGamingWiki's own word, not a medal.
    static func nativeLabel(_ tier: String) -> String {
        switch tier {
        case "perfect": "Perfect"
        case "playable": "Playable"
        case "runs": "Runs"
        default: "Unplayable"
        }
    }

    static func nativeState(_ tier: String) -> GameCompatBadge.State {
        switch tier {
        case "perfect": .verified
        case "playable", "runs": .playable
        default: .unsupported
        }
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

        /// Read by hand: `storeIds` mixes strings and objects, and one odd
        /// record must not lose the table.
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

    /// One ProtonDB summary; anything off the JSON shape (a 404 page) is
    /// absent.
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

    /// One game's summary (`GET /v1/games/<appid>`); a 404, cached as `{}`,
    /// reads as absent.
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
            let left_out: Int?
            let reached_frame: Double?
            let played: Double?
            let crashed: Double?
        }
        guard let summary = try? JSONDecoder().decode(Summary.self, from: data) else { return nil }
        return GameCompatRecord.Community(
            verdict: summary.verdict, runs: summary.runs, installs: summary.installs,
            engine: summary.engine, medianFPS: summary.fps?.median_avg, pageURL: summary.url,
            leftOut: summary.left_out ?? 0, reachedFrame: summary.reached_frame,
            played: summary.played, crashed: summary.crashed,
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

    /// PCGamingWiki's page title for a Steam app id.
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
