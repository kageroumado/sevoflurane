import AppKit
import Foundation
import Observation

/// Whether a run whose video decoded nothing earns the offer of the other decoder.
nonisolated enum VideoDecodingPromptPolicy {
    /// The suggestion to offer for `record`, unless the crash prompt opened.
    ///
    /// - Parameters:
    ///   - crashShown: Whether the crash prompt opened; a run gets one panel.
    ///   - current: The game's video decoding as it resolves now.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(
        for record: RunRecord, crashShown: Bool, current: VideoDecoding, asks: Bool,
    ) -> VideoDecodingDiagnosis.Suggestion? {
        guard !crashShown else { return nil }
        return VideoDecodingDiagnosis.suggestion(for: record, current: current, asks: asks)
    }
}

/// What the offer says and its three answers.
@MainActor
@Observable
final class VideoDecodingPromptModel {
    let record: RunRecord
    let suggestion: VideoDecodingDiagnosis.Suggestion
    /// Called when the panel has nothing left to ask.
    var onFinish: (() -> Void)?

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment

    init(
        record: RunRecord, suggestion: VideoDecodingDiagnosis.Suggestion,
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
        return String(localized: "\(name) is waiting on a video that decodes nothing")
    }

    var body: String {
        let buffers = suggestion.video.buffers
        let stream = suggestion.video.stream
        return switch suggestion.offered {
        case .software:
            String(localized: "Its video decoder was given \(buffers) frames of \(stream) and returned none, so the game shows a blank picture where the video should play. The Mac's hardware decoder could not read this stream; GStreamer's software decoders usually can.")
        case .hardware:
            String(localized: "Its video decoder was given \(buffers) frames of \(stream) and returned none, so the game shows a blank picture where the video should play. The software decoders could not read this stream; the Mac's hardware decoder may.")
        }
    }

    var switchTitle: String {
        switch suggestion.offered {
        case .software: String(localized: "Use Software Decoding")
        case .hardware: String(localized: "Use Hardware Decoding")
        }
    }

    /// Sets the game's video decoding to the offered one for its next launch.
    func switchDecoding() {
        let offered = suggestion.offered
        settings.update(.game(record.appid, bottle: SteamBottle.name)) { $0.videoDecoding = offered }
        EventLog.enqueue(.client, "video decoding applied — \(record.appid) set to \(offered.rawValue)")
        onFinish?()
    }

    func notNow() {
        onFinish?()
    }

    func stopAsking() {
        Preferences.stopAskingAboutVideoDecoding(forApp: record.appid, in: defaults)
        onFinish?()
    }
}
