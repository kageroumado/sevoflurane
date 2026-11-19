import Foundation

/// The offer of the other decoder for a game whose video decoded nothing,
/// once per run: mid-run when the engine's line arrives in time, otherwise at
/// the close.
@MainActor
final class VideoDecodingPrompt {
    static let shared = VideoDecodingPrompt()

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let presenter: ((RunRecord, VideoDecodingDiagnosis.Suggestion) -> Void)?
    private var considered: Set<String> = []
    private let panel = SettingOfferPanel()

    /// - Parameters:
    ///   - defaults: Where "Don't Ask for This Game" is read from and written to.
    ///   - settings: Where the game's video decoding is read and written.
    ///   - presenter: A test's stand-in for opening the panel.
    init(
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        presenter: ((RunRecord, VideoDecodingDiagnosis.Suggestion) -> Void)? = nil,
    ) {
        self.defaults = defaults
        self.settings = settings
        self.presenter = presenter
    }

    /// Considers a run, open or closed, once; answers whether it opened the prompt.
    @discardableResult
    func offer(_ record: RunRecord, crashShown: Bool) -> Bool {
        let key = CrashPromptPolicy.key(for: record)
        guard !considered.contains(key) else { return false }
        considered.insert(key)
        guard let suggestion = VideoDecodingPromptPolicy.suggestion(
            for: record, crashShown: crashShown, current: currentDecoding(forApp: record.appid),
            asks: Preferences.asksAboutVideoDecoding(forApp: record.appid, in: defaults),
        ) else { return false }
        EventLog.enqueue(
            .client,
            "video decoding offered — \(record.appid) decoded none of \(suggestion.video.buffers) "
                + "\(suggestion.video.stream) buffers on \(suggestion.current.rawValue), "
                + "offering \(suggestion.offered.rawValue)",
        )
        if let presenter {
            presenter(record, suggestion)
        } else {
            present(record, suggestion)
        }
        return true
    }

    private func currentDecoding(forApp appID: Int) -> VideoDecoding {
        settings.resolved(SettingCatalog.setting(.videoDecoding), bottle: SteamBottle.name, game: appID)
            .choice.flatMap(VideoDecoding.init(rawValue:)) ?? .hardware
    }

    private func present(_ record: RunRecord, _ suggestion: VideoDecodingDiagnosis.Suggestion) {
        let model = VideoDecodingPromptModel(
            record: record, suggestion: suggestion, defaults: defaults, settings: settings,
        )
        model.onFinish = { [panel] in panel.close() }
        panel.present(SettingOffer(
            symbol: "film",
            title: model.title,
            summary: record.displaySummary,
            message: model.body,
            footnote: String(localized: "The change takes effect the next time the game starts. It is the Video decoding row in the game's settings."),
            acceptTitle: model.switchTitle,
            accept: model.switchDecoding,
            notNow: model.notNow,
            stopAsking: model.stopAsking,
        ))
    }
}
