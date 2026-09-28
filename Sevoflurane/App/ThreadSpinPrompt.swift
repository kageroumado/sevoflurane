import AppKit
import Propofol
import SwiftUI

/// Whether a closed run earns the processor-limit offer. Pure, so the decision
/// is testable without a window.
nonisolated enum ThreadSpinPromptPolicy {
    /// The suggestion to offer for `record`: the diagnosis, when the crash
    /// prompt left the run to it.
    ///
    /// - Parameters:
    ///   - crashShown: Whether the crash prompt opened for this run. A crash is
    ///     the news, and one panel is what a run gets.
    ///   - currentCap: The game's processors setting as it resolves now.
    ///   - asks: Whether the offer is still wanted for this game.
    static func suggestion(
        for record: RunRecord, crashShown: Bool, currentCap: Int?, asks: Bool,
    ) -> ThreadSpinDiagnosis.Suggestion? {
        guard !crashShown else { return nil }
        return ThreadSpinDiagnosis.suggestion(for: record, currentCap: currentCap, asks: asks)
    }
}

/// The offer after a run whose game kept a thread spinning on every processor:
/// one panel, once per run, naming how many and offering the cap that lets
/// them sleep.
///
/// A floating panel for the same reason as ``CrashPrompt``'s: the app is a
/// menu-bar agent and the game that just closed may have been its only window.
@MainActor
final class ThreadSpinPrompt: NSObject, NSWindowDelegate {
    static let shared = ThreadSpinPrompt()

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let presenter: ((RunRecord, ThreadSpinDiagnosis.Suggestion) -> Void)?
    private var considered: Set<String> = []
    private var panel: NSPanel?
    private var model: ThreadSpinPromptModel?

    /// - Parameters:
    ///   - defaults: Where "Don't Ask for This Game" is read from and written to.
    ///   - settings: Where the game's processors setting is read and written.
    ///   - presenter: What showing the prompt means. A test injects one; the
    ///     app opens the panel.
    init(
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        presenter: ((RunRecord, ThreadSpinDiagnosis.Suggestion) -> Void)? = nil,
    ) {
        self.defaults = defaults
        self.settings = settings
        self.presenter = presenter
    }

    /// Considers a closed run, and answers whether it opened the prompt. A run
    /// is considered once: the second closing of a run whose first closing
    /// showed the crash prompt stays with that answer.
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
        model.onFinish = { [weak self] in self?.close() }
        self.model = model
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ThreadSpinPromptView(model: model))
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

    /// Sets the game's processors to the suggested cap through the store Settings
    /// writes, which the next launch reads.
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

// MARK: - The view

private struct ThreadSpinPromptView: View {
    let model: ThreadSpinPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            Text(model.body)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text("The limit takes effect the next time the game starts.")
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
            Image(systemName: "cpu")
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
            Button(model.limitTitle) { model.limit() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
