import Foundation

/// The first-run assistant's page.
nonisolated enum SetupScreen: String, CaseIterable, Sendable {
    case welcome
    /// Asked on a Mac with more than one Steam.
    case whichSteam
    /// Asked where a new Steam could run on either engine.
    case engine
    /// The work, and the questions asked during it.
    case progress
    case done
}

/// A question the progress page asks while the work runs.
nonisolated enum SetupCard: String, CaseIterable, Sendable {
    case sharing
    case toolkit
}

/// A Steam already on this Mac that setup can take over, with what tells it
/// from the others.
nonisolated struct SteamCandidate: Equatable, Identifiable, Sendable {
    let bottle: SetupDetection.Bottle
    /// Whether it lives with the built-in engine; otherwise with CrossOver.
    let isManaged: Bool
    var facts = SteamLibraryFacts()

    var id: URL {
        bottle.url
    }
}

/// The rules of the first-run assistant, as functions of what the Mac has
/// and what has been answered: which pages there are, what each starts on,
/// and whether the assistant opens at all.
nonisolated enum SetupFlow {
    /// What the pages depend on.
    struct Facts: Equatable, Sendable {
        /// The Steams setup could take over.
        var candidates: [SteamCandidate] = []
        var hasUsableCrossOver = false
        /// The Steam the person chose on its page, `nil` for a new one.
        var chosenSteam: SteamCandidate.ID?
    }

    /// Whether the assistant asks which Steam: only among several.
    static func asksWhichSteam(_ facts: Facts) -> Bool {
        facts.candidates.count > 1
    }

    /// The Steam setup takes over: the chosen one among several, the only
    /// one where there is one, none on a Mac without Steam.
    static func adopted(_ facts: Facts) -> SteamCandidate? {
        guard asksWhichSteam(facts) else { return facts.candidates.first }
        return facts.candidates.first { $0.id == facts.chosenSteam }
    }

    /// Whether the assistant asks which engine: a new Steam on a Mac where
    /// CrossOver can run it too. An existing Steam lives with one engine
    /// already.
    static func asksEngine(_ facts: Facts) -> Bool {
        facts.hasUsableCrossOver && adopted(facts) == nil
    }

    /// The question pages in order, between the welcome and the work.
    static func questions(_ facts: Facts) -> [SetupScreen] {
        var pages: [SetupScreen] = []
        if asksWhichSteam(facts) { pages.append(.whichSteam) }
        if asksEngine(facts) { pages.append(.engine) }
        return pages
    }

    /// The screen after `screen`; the work follows the last question.
    static func screen(after screen: SetupScreen, _ facts: Facts) -> SetupScreen {
        let pages = [.welcome] + questions(facts) + [.progress, .done]
        guard let index = pages.firstIndex(of: screen), index + 1 < pages.count else { return .progress }
        return pages[index + 1]
    }

    /// The page Back leads to from a question page, where nothing has been
    /// touched yet; `nil` on every other page.
    static func screen(before screen: SetupScreen, _ facts: Facts) -> SetupScreen? {
        let pages = [.welcome] + questions(facts)
        guard let index = pages.firstIndex(of: screen), index > 0 else { return nil }
        return pages[index - 1]
    }

    /// The Steam the page starts on: the one played most recently, else the
    /// one this installation already drives, else the first.
    static func preselectedSteam(among candidates: [SteamCandidate], storedName: String) -> SteamCandidate.ID? {
        let played = candidates.filter { $0.facts.lastPlayed != nil }
        if let latest = played.max(by: { ($0.facts.lastPlayed ?? .distantPast) < ($1.facts.lastPlayed ?? .distantPast) }) {
            return latest.id
        }
        return (candidates.first { $0.bottle.name == storedName } ?? candidates.first)?.id
    }

    /// Whether setup starts on CrossOver where both engines can run a new
    /// Steam: the stored choice, else CrossOver only where Steam already
    /// sits in a CrossOver bottle, else the built-in engine. Without a
    /// usable CrossOver the answer is the built-in engine.
    static func startsOnCrossOver(
        hasUsableCrossOver: Bool, storedChoiceIsManaged: Bool?, steamIsInCrossOver: Bool,
    ) -> Bool {
        guard hasUsableCrossOver else { return false }
        if let storedChoiceIsManaged { return !storedChoiceIsManaged }
        return steamIsInCrossOver
    }

    /// The folder name of a new Steam: the stored name while no Steam holds
    /// it, so a folder an interrupted setup began is taken up again; else
    /// the first free of "Steam", "Steam 2", "Steam 3".
    static func newSteamName(stored: String, base: String, bottles: [SetupDetection.Bottle]) -> String {
        if !bottles.contains(where: { $0.name == stored && $0.hasSteam }) { return stored }
        let taken = Set(bottles.map(\.name))
        if !taken.contains(base) { return base }
        return (2...).lazy.map { "\(base) \($0)" }.first { !taken.contains($0) } ?? base
    }

    /// The questions the progress page still has to ask, in order.
    static func cards(sharingIsAnswered: Bool, offersToolkit: Bool) -> [SetupCard] {
        var cards: [SetupCard] = []
        if !sharingIsAnswered { cards.append(.sharing) }
        if offersToolkit { cards.append(.toolkit) }
        return cards
    }

    /// How the assistant opens at launch.
    enum Opening: Equatable, Sendable {
        /// Steam is installed and no assistant was left unfinished.
        case closed
        /// Steam is missing: the assistant starts at its welcome.
        case fromWelcome
        /// Steam is installed and an assistant was quit before its last
        /// page: it opens on what is left to answer.
        case resumed
    }

    /// A Mac with Steam installed and no assistant on record is finished,
    /// whichever version set it up.
    static func opening(needsSetup: Bool, assistantInProgress: Bool) -> Opening {
        if needsSetup { return .fromWelcome }
        return assistantInProgress ? .resumed : .closed
    }
}
