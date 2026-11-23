import Foundation
import Testing
@testable import Sevoflurane

/// The first-run assistant's rules: which pages a Mac gets, what each starts
/// on, and whether the assistant opens at all.
struct SetupFlowTests {
    private func candidate(_ name: String, managed: Bool = true, lastPlayed: Date? = nil) -> SteamCandidate {
        SteamCandidate(
            bottle: SetupDetection.Bottle(
                name: name, url: URL(fileURLWithPath: "/bottles/\(managed ? "own" : "crossover")/\(name)"), hasSteam: true,
            ),
            isManaged: managed,
            facts: SteamLibraryFacts(games: 3, lastPlayed: lastPlayed, bytes: 1_000_000),
        )
    }

    // MARK: - Pages

    @Test
    func `a Mac with nothing on it goes from the welcome to the work`() {
        let facts = SetupFlow.Facts()
        #expect(SetupFlow.questions(facts).isEmpty)
        #expect(SetupFlow.screen(after: .welcome, facts) == .progress)
        #expect(SetupFlow.screen(after: .progress, facts) == .done)
        #expect(SetupFlow.screen(before: .welcome, facts) == nil)
        #expect(SetupFlow.screen(before: .progress, facts) == nil)
    }

    @Test
    func `one Steam is taken over with no question`() {
        let only = candidate("Games")
        let facts = SetupFlow.Facts(candidates: [only], hasUsableCrossOver: true)
        #expect(SetupFlow.questions(facts).isEmpty)
        #expect(SetupFlow.adopted(facts) == only)
    }

    @Test
    func `several Steams are asked about, and an existing one settles the engine`() {
        let first = candidate("Steam", managed: false)
        let second = candidate("Games")
        var facts = SetupFlow.Facts(candidates: [first, second], hasUsableCrossOver: true, chosenSteam: second.id)
        #expect(SetupFlow.questions(facts) == [.whichSteam])
        #expect(SetupFlow.adopted(facts) == second)
        #expect(SetupFlow.screen(after: .welcome, facts) == .whichSteam)
        #expect(SetupFlow.screen(after: .whichSteam, facts) == .progress)
        #expect(SetupFlow.screen(before: .whichSteam, facts) == .welcome)

        facts.chosenSteam = nil
        #expect(SetupFlow.questions(facts) == [.whichSteam, .engine])
        #expect(SetupFlow.screen(after: .whichSteam, facts) == .engine)
        #expect(SetupFlow.screen(after: .engine, facts) == .progress)
        #expect(SetupFlow.screen(before: .engine, facts) == .whichSteam)
    }

    @Test
    func `a new Steam asks for the engine only where CrossOver can run it`() {
        #expect(SetupFlow.questions(SetupFlow.Facts(hasUsableCrossOver: true)) == [.engine])
        #expect(SetupFlow.questions(SetupFlow.Facts(hasUsableCrossOver: false)).isEmpty)
        let facts = SetupFlow.Facts(hasUsableCrossOver: true)
        #expect(SetupFlow.screen(before: .engine, facts) == .welcome)
    }

    // MARK: - Defaults

    @Test
    func `the Steam played last is the one the page starts on`() {
        let old = candidate("Steam", lastPlayed: Date(timeIntervalSince1970: 1000))
        let recent = candidate("Games", lastPlayed: Date(timeIntervalSince1970: 9000))
        let never = candidate("Beta")
        #expect(SetupFlow.preselectedSteam(among: [old, recent, never], storedName: "Steam") == recent.id)
        #expect(SetupFlow.preselectedSteam(among: [never, candidate("Other")], storedName: "Other")?.lastPathComponent == "Other")
        #expect(SetupFlow.preselectedSteam(among: [never], storedName: "Steam") == never.id)
        #expect(SetupFlow.preselectedSteam(among: [], storedName: "Steam") == nil)
    }

    @Test
    func `the engine default is the stored choice, then where Steam sits, then the built-in one`() {
        #expect(!SetupFlow.startsOnCrossOver(hasUsableCrossOver: true, storedChoiceIsManaged: nil, steamIsInCrossOver: false))
        #expect(SetupFlow.startsOnCrossOver(hasUsableCrossOver: true, storedChoiceIsManaged: nil, steamIsInCrossOver: true))
        #expect(SetupFlow.startsOnCrossOver(hasUsableCrossOver: true, storedChoiceIsManaged: false, steamIsInCrossOver: false))
        #expect(!SetupFlow.startsOnCrossOver(hasUsableCrossOver: true, storedChoiceIsManaged: true, steamIsInCrossOver: true))
        // A stored CrossOver choice is no use once CrossOver cannot run.
        #expect(!SetupFlow.startsOnCrossOver(hasUsableCrossOver: false, storedChoiceIsManaged: false, steamIsInCrossOver: true))
    }

    @Test
    func `a new Steam takes up the folder an interrupted setup began`() {
        let unfinished = SetupDetection.Bottle(name: "Steam", url: URL(fileURLWithPath: "/b/Steam"), hasSteam: false)
        #expect(SetupFlow.newSteamName(stored: "Steam", base: "Steam", bottles: [unfinished]) == "Steam")
        #expect(SetupFlow.newSteamName(stored: "Steam", base: "Steam", bottles: []) == "Steam")
    }

    @Test
    func `a new Steam beside existing ones gets the first free name`() {
        func bottle(_ name: String, steam: Bool = true) -> SetupDetection.Bottle {
            SetupDetection.Bottle(name: name, url: URL(fileURLWithPath: "/b/\(name)"), hasSteam: steam)
        }
        #expect(SetupFlow.newSteamName(stored: "Steam", base: "Steam", bottles: [bottle("Steam")]) == "Steam 2")
        #expect(
            SetupFlow.newSteamName(
                stored: "Steam", base: "Steam", bottles: [bottle("Steam"), bottle("Steam 2", steam: false)],
            ) == "Steam 3",
        )
        #expect(SetupFlow.newSteamName(stored: "Games", base: "Steam", bottles: [bottle("Games")]) == "Steam")
    }

    // MARK: - Questions during the work

    @Test
    func `the progress page asks sharing first, then the toolkit, each only when open`() {
        #expect(SetupFlow.cards(sharingIsAnswered: false, offersToolkit: true) == [.sharing, .toolkit])
        #expect(SetupFlow.cards(sharingIsAnswered: true, offersToolkit: true) == [.toolkit])
        #expect(SetupFlow.cards(sharingIsAnswered: false, offersToolkit: false) == [.sharing])
        #expect(SetupFlow.cards(sharingIsAnswered: true, offersToolkit: false).isEmpty)
    }

    // MARK: - Whether the assistant opens

    @Test
    func `a fresh Mac opens the assistant at its welcome`() {
        #expect(SetupFlow.opening(needsSetup: true, assistantInProgress: false) == .fromWelcome)
        #expect(SetupFlow.opening(needsSetup: true, assistantInProgress: true) == .fromWelcome)
    }

    @Test
    func `an assistant quit after Steam installed opens on what is left`() {
        #expect(SetupFlow.opening(needsSetup: false, assistantInProgress: true) == .resumed)
    }

    @Test
    func `an installation set up under an earlier version never sees the assistant`() {
        #expect(SetupFlow.opening(needsSetup: false, assistantInProgress: false) == .closed)
    }

    // MARK: - Failure words

    @Test
    func `a network error is said in the system's sentence, with advice`() {
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, userInfo: [
            NSLocalizedDescriptionKey: "The Internet connection appears to be offline.",
            NSURLErrorFailingURLStringErrorKey: "https://example.com/engine.tar.xz",
        ])
        #expect(SetupFailureText.sentence(offline) == "The Internet connection appears to be offline.")
        #expect(SetupFailureText.advice(offline) != nil)
    }

    @Test
    func `the app's own error is its description as a sentence`() {
        struct Own: Error, CustomStringConvertible {
            let description = "engine tarball hash mismatch: abc"
        }
        #expect(SetupFailureText.sentence(Own()) == "Engine tarball hash mismatch: abc.")
        #expect(SetupFailureText.advice(Own()) == nil)
    }

    @Test
    func `a library is counted from its manifests`() {
        var facts = SteamLibraryFacts()
        facts.add(manifest: "\"AppState\"\n{\n\t\"appid\"\t\t\"620\"\n\t\"SizeOnDisk\"\t\t\"12000000000\"\n\t\"LastPlayed\"\t\t\"1700000000\"\n}")
        facts.add(manifest: "\"AppState\"\n{\n\t\"SizeOnDisk\"\t\t\"500\"\n\t\"LastPlayed\"\t\t\"0\"\n}")
        #expect(facts.games == 2)
        #expect(facts.bytes == 12_000_000_500)
        #expect(facts.lastPlayed == Date(timeIntervalSince1970: 1_700_000_000))
    }
}
