import AppKit
import Propofol
import SwiftUI

/// Whether a run whose video decoded nothing earns the offer of the other
/// decoder. Pure, so the decision is testable without a window.
nonisolated enum VideoDecodingPromptPolicy {
    /// The suggestion to offer for `record`: the diagnosis, when the crash
    /// prompt left the run to it.
    ///
    /// - Parameters:
    ///   - crashShown: Whether the crash prompt opened for this run. A crash is
    ///     the news, and one panel is what a run gets.
    ///   - current: The game's video decoding as it resolves now.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(
        for record: RunRecord, crashShown: Bool, current: VideoDecoding, asks: Bool,
    ) -> VideoDecodingDiagnosis.Suggestion? {
        guard !crashShown else { return nil }
        return VideoDecodingDiagnosis.suggestion(for: record, current: current, asks: asks)
    }
}

/// The offer for a game whose video decoder was fed and produced nothing: one
/// panel, once per run, opened while the game still waits on the blank
/// picture when the engine's line arrives in time, otherwise at the run's
/// close. It names the stream and offers the other decoder.
///
/// A floating panel for the same reason as ``CrashPrompt``'s: the app is a
/// menu-bar agent and the game may be the only window on screen.
@MainActor
final class VideoDecodingPrompt: NSObject, NSWindowDelegate {
    static let shared = VideoDecodingPrompt()

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let presenter: ((RunRecord, VideoDecodingDiagnosis.Suggestion) -> Void)?
    private var considered: Set<String> = []
    private var panel: NSPanel?
    private var model: VideoDecodingPromptModel?

    /// - Parameters:
    ///   - defaults: Where "Don't Ask for This Game" is read from and written to.
    ///   - settings: Where the game's video decoding is read and written.
    ///   - presenter: What showing the prompt means. A test injects one; the
    ///     app opens the panel.
    init(
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        presenter: ((RunRecord, VideoDecodingDiagnosis.Suggestion) -> Void)? = nil,
    ) {
        self.defaults = defaults
        self.settings = settings
        self.presenter = presenter
    }

    /// Considers a run, open or closed, and answers whether it opened the
    /// prompt. A run is considered once: the offer that opened while it ran
    /// is its one, and its close brings no second.
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
        model.onFinish = { [weak self] in self?.close() }
        self.model = model
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: VideoDecodingPromptView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? Self.panelSize)
        panel.center()
        // An agent app has no activation of its own, so the panel would open
        // behind whatever the user was in.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        model = nil
    }

    private static let panelSize = NSSize(width: 460, height: 200)

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false,
        )
        panel.delegate = self
        panel.title = "Sevoflurane"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    /// The close button is "Not Now".
    func windowShouldClose(_: NSWindow) -> Bool {
        model?.notNow()
        return false
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

    /// Sets the game's video decoding to the offered one through the store
    /// Settings writes, which the next launch reads.
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

// MARK: - The view

private struct VideoDecodingPromptView: View {
    let model: VideoDecodingPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            Text(model.body)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text("The change takes effect the next time the game starts. It is the Video decoding row in the game's settings.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            choices
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "film")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(model.record.displaySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var choices: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Don't Ask for This Game") { model.stopAsking() }
            Spacer()
            Button("Not Now") { model.notNow() }
                .keyboardShortcut(.cancelAction)
            Button(model.switchTitle) { model.switchDecoding() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
