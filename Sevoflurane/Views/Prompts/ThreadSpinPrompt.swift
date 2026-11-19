import AppKit
import Propofol
import SwiftUI

/// The offer after a run whose game kept a thread spinning on every
/// processor, with the cap that lets them sleep. A floating panel, like
/// ``CrashPrompt``'s, since a menu-bar agent may have no other window.
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
        model.onFinish = { [weak self] in self?.close() }
        self.model = model
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: ThreadSpinPromptView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? Self.panelSize)
        panel.center()
        // Otherwise the agent app's panel opens behind the front app.
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
