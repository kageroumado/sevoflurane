import Foundation

/// The offer after a run whose game kept a thread spinning on every
/// processor, with the cap that lets them sleep.
@MainActor
final class ThreadSpinPrompt {
    static let shared = ThreadSpinPrompt()

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let presenter: ((RunRecord, ThreadSpinDiagnosis.Suggestion) -> Void)?
    private var considered: Set<String> = []
    private let panel = SettingOfferPanel()

    /// - Parameters:
    ///   - defaults: Where "Don't Ask for This Game" is read from and written to.
    ///   - settings: Where the game's processors setting is read and written.
    ///   - presenter: A test's stand-in for opening the panel.
    init(
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        presenter: ((RunRecord, ThreadSpinDiagnosis.Suggestion) -> Void)? = nil,
    ) {
        self.defaults = defaults
        self.settings = settings
        self.presenter = presenter
    }

    /// Considers a closed run once, answering whether it opened the prompt.
    @discardableResult
    func offer(_ record: RunRecord, crashShown: Bool) -> Bool {
        let key = CrashPromptPolicy.key(for: record)
        guard !considered.contains(key) else { return false }
        considered.insert(key)
        guard let suggestion = ThreadSpinPromptPolicy.suggestion(
            for: record, crashShown: crashShown, currentCap: currentCap(forApp: record.appid),
            asks: Preferences.asksAboutThreadSpin(forApp: record.appid, in: defaults),
        ) else { return false }
        EventLog.enqueue(
            .client,
            "processor limit offered — \(record.appid) kept \(suggestion.busy) of \(suggestion.processors) "
                + "processors busy, cap \(suggestion.cap)",
        )
        if let presenter {
            presenter(record, suggestion)
        } else {
            present(record, suggestion)
        }
        return true
    }

    private func currentCap(forApp appID: Int) -> Int? {
        settings.resolved(SettingCatalog.setting(.processors), bottle: SteamBottle.name, game: appID)
            .choice.flatMap { Int($0) }
    }

    private func present(_ record: RunRecord, _ suggestion: ThreadSpinDiagnosis.Suggestion) {
        let model = ThreadSpinPromptModel(
            record: record, suggestion: suggestion, defaults: defaults, settings: settings,
        )
        model.onFinish = { [panel] in panel.close() }
        panel.present(SettingOffer(
            symbol: "cpu",
            title: model.title,
            summary: record.displaySummary,
            message: model.body,
            footnote: String(localized: "The limit takes effect the next time the game starts."),
            acceptTitle: model.limitTitle,
            accept: model.limit,
            notNow: model.notNow,
            stopAsking: model.stopAsking,
        ))
    }
}
