import AppKit
import SwiftUI

/// The one panel that tells a user what happened to a run and what to do: it
/// reads the run's findings (``RunDiagnosis``) when the run closes, or while
/// it is up for what cannot wait, and opens for the ones that are raised. A
/// floating panel, since the game that just died may have been the only window
/// on screen; never a modal session.
@MainActor
final class RunDiagnosisPrompt: NSObject, NSWindowDelegate {
    static let shared = RunDiagnosisPrompt()

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let suggested: () -> [SuggestedFix]
    private let presenter: ((RunRecord, [RunDiagnosis.Finding]) -> Void)?
    /// Shows a place in the app that a finding points at.
    var showGuide: (RunDiagnosis.Guide, RunRecord) -> Void = { _, _ in }

    /// The causes each run was already shown, by ``RunRecord/id``: a run is
    /// told of each once, whether it closes twice (a reattach, then the
    /// client's notification) or was told of one while it was up.
    private var shown: [String: Set<RunDiagnosis.Cause>] = [:]
    private let panel = DialogPanel(size: NSSize(width: RunDiagnosisView.width, height: 220), title: "Sevoflurane")
    private var model: RunDiagnosisModel?
    /// Runs that ended while the panel was up, in order.
    private var waiting: [(record: RunRecord, findings: [RunDiagnosis.Finding])] = []

    /// - Parameters:
    ///   - defaults: Where the mutes and "Never ask again" are read from and written to.
    ///   - settings: Where the game's settings are read and written.
    ///   - suggested: The fixes other Macs' runs suggest.
    ///   - presenter: What showing the panel means. A test injects one; the app opens the panel.
    init(
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        suggested: @escaping () -> [SuggestedFix] = { FixList.suggested },
        presenter: ((RunRecord, [RunDiagnosis.Finding]) -> Void)? = nil,
    ) {
        self.defaults = defaults
        self.settings = settings
        self.suggested = suggested
        self.presenter = presenter
    }

    /// Points the recorder's closing hook at this panel, and the
    /// decoded-nothing hook too, which fires while the game still waits on its
    /// picture. The hooks fire on the recorder's queues.
    func install() {
        RunRecorder.didClose = { [weak self] record in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.offer(record) }
            }
        }
        RunRecorder.didStarveVideo = { [weak self] record in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { _ = self?.offer(record) }
            }
        }
    }

    /// Considers a run, open or closed, and answers whether it opened the
    /// panel (or queued it behind the one that is up).
    @discardableResult
    func offer(_ record: RunRecord) -> Bool {
        let raised = RunDiagnosis.raised(
            findings(for: record),
            quiet: Preferences.quietCauses(forApp: record.appid, in: defaults),
            asksAfterBadEnding: Preferences.asksAfterCrash(in: defaults),
        )
        let fresh = raised.filter { shown[record.id]?.contains($0.cause) != true }
        guard !fresh.isEmpty else { return false }
        shown[record.id, default: []].formUnion(fresh.map(\.cause))
        EventLog.enqueue(
            .client,
            "run findings offered — \(record.appid): " + fresh.map(\.cause.rawValue).joined(separator: ", "),
        )
        if let presenter {
            presenter(record, fresh)
        } else {
            present(record, fresh)
        }
        return true
    }

    /// Every finding about `record` with this Mac's settings and the suggested
    /// fixes, which are read only for a run that ended badly.
    func findings(for record: RunRecord) -> [RunDiagnosis.Finding] {
        let bottle = settings.values(.bottle(SteamBottle.name)).fields
        let own = settings.values(.game(record.appid, bottle: SteamBottle.name)).fields
        let context = RunDiagnosis.Context(
            current: ConfigValues(fields: bottle.merging(own) { _, own in own }) ?? .empty,
            suggested: RunDiagnosis.endedBadly(record) ? suggested() : [],
        )
        return RunDiagnosis.findings(for: record, in: context)
    }

    private func present(_ record: RunRecord, _ findings: [RunDiagnosis.Finding]) {
        guard model == nil else {
            waiting.append((record, findings))
            return
        }
        let model = RunDiagnosisModel(
            record: record, findings: findings, defaults: defaults, settings: settings, open: showGuide,
        )
        model.onFinish = { [weak self] in self?.close() }
        self.model = model
        panel.delegate = self
        panel.show(RunDiagnosisView(model: model))
    }

    private func close() {
        panel.dismiss()
        model = nil
        guard !waiting.isEmpty else { return }
        let next = waiting.removeFirst()
        present(next.record, next.findings)
    }

    /// Escape is the answer that takes nothing.
    func windowShouldClose(_: NSWindow) -> Bool {
        model?.dismiss()
        return false
    }

    #if DEBUG
        /// Whether this launch asked for the panel on a fixture run
        /// (`SEVO_DEMO_CRASH=1` or `--demo-crash`). The panel, zip and upload
        /// are real; only the run is made up.
        static var wasRequestedAtLaunch: Bool {
            ProcessInfo.processInfo.environment["SEVO_DEMO_CRASH"] != nil
                || CommandLine.arguments.contains("--demo-crash")
        }

        /// Opens the panel on a crashed fixture run shaped like the recorder's.
        func offerFixture() {
            offer(RunRecord(
                t: ISO8601DateFormatter().string(from: Date()),
                appid: 1_962_700,
                name: "Subnautica 2",
                engine: Engine.active.description,
                renderer: "dxmt",
                runner: "wine",
                windows: "fixed",
                msync: true,
                macos: ProcessInfo.processInfo.operatingSystemVersionString,
                durationSeconds: 61,
                exit: RunRecord.Exit(kind: .crash, code: 3),
                host: RunRecord.Host(thermal: "nominal", load: 1),
            ))
        }
    #endif
}
