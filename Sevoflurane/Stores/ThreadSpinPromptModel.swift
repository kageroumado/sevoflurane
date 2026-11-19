import AppKit
import Foundation
import Observation

/// Whether a closed run earns the processor-limit offer.
nonisolated enum ThreadSpinPromptPolicy {
    /// The suggestion to offer for `record`, unless the crash prompt opened.
    ///
    /// - Parameters:
    ///   - crashShown: Whether the crash prompt opened; a run gets one panel.
    ///   - currentCap: The game's processors setting as it resolves now.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(
        for record: RunRecord, crashShown: Bool, currentCap: Int?, asks: Bool,
    ) -> ThreadSpinDiagnosis.Suggestion? {
        guard !crashShown else { return nil }
        return ThreadSpinDiagnosis.suggestion(for: record, currentCap: currentCap, asks: asks)
    }
}

/// What the offer says and its three answers.
@MainActor
@Observable
final class ThreadSpinPromptModel {
    let record: RunRecord
    let suggestion: ThreadSpinDiagnosis.Suggestion
    /// Called when the panel has nothing left to ask.
    var onFinish: (() -> Void)?

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment

    init(
        record: RunRecord, suggestion: ThreadSpinDiagnosis.Suggestion,
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
    ) {
        self.record = record
        self.suggestion = suggestion
        self.defaults = defaults
        self.settings = settings
    }

    var title: String {
        let name = record.name ?? String(localized: "The game")
        return String(localized: "\(name) kept \(suggestion.busy) threads busy the whole time")
    }

    var body: String {
        String(localized: "Games built this way start one worker per processor, and under Rosetta the workers never rest, which starves the picture. Telling the game it has \(suggestion.cap) processors lets them sleep.")
    }

    var limitTitle: String {
        String(localized: "Limit to \(suggestion.cap) Processors")
    }

    /// Sets the game's processors to the cap for its next launch.
    func limit() {
        let cap = suggestion.cap
        settings.update(.game(record.appid, bottle: SteamBottle.name)) { $0.processors = cap }
        EventLog.enqueue(.client, "processor limit applied — \(record.appid) told of \(cap) processors")
        onFinish?()
    }

    func notNow() {
        onFinish?()
    }

    func stopAsking() {
        Preferences.stopAskingAboutThreadSpin(forApp: record.appid, in: defaults)
        onFinish?()
    }
}
