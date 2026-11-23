import Foundation
import Observation

/// What the panel about one run knows and does: its findings
/// (``RunDiagnosis``), the action each offers, and the report.
@MainActor
@Observable
final class RunDiagnosisModel {
    /// The two things the panel can be asking.
    enum Face: Equatable {
        /// What happened, with the first finding's action.
        case findings
        /// Whether to send the report.
        case report
    }

    /// What an action that takes time is doing.
    enum Progress: Equatable {
        case working(String)
        case failed(String)
    }

    let record: RunRecord
    /// In ``RunDiagnosis/order``, never empty; the first leads the panel.
    let findings: [RunDiagnosis.Finding]
    /// The report's send flow.
    let report: ReportSendModel
    private(set) var face: Face
    private(set) var progress: Progress?
    /// The findings whose action was taken here.
    private(set) var taken: Set<RunDiagnosis.Cause> = []
    /// "Don't show this again for this game."
    var stopsAsking = false
    /// Called when the panel has nothing left to ask.
    var onFinish: (() -> Void)?

    private let defaults: UserDefaults
    private let settings: any SettingsEnvironment
    private let dependencies: any CompatibilityEnvironment
    /// Where the applied fixes are recorded for Undo; nil records nothing.
    private let ledger: URL?
    private let open: (RunDiagnosis.Guide, RunRecord) -> Void
    @ObservationIgnored private var installing: Task<Void, Never>?

    /// - Parameters:
    ///   - findings: What to show, the first leading; a diagnosis' raised findings.
    ///   - ledger: The fix ledger's folder; the gallery passes nil.
    ///   - open: Shows a place in the app a finding points at.
    init(
        record: RunRecord,
        findings: [RunDiagnosis.Finding],
        report: ReportSendModel? = nil,
        defaults: UserDefaults = Preferences.shared,
        settings: any SettingsEnvironment = LiveSettingsEnvironment(),
        dependencies: any CompatibilityEnvironment = LiveCompatibilityEnvironment(),
        ledger: URL? = FixLedger.root,
        open: @escaping (RunDiagnosis.Guide, RunRecord) -> Void = { _, _ in },
    ) {
        precondition(!findings.isEmpty, "a panel needs a finding")
        self.record = record
        self.findings = findings
        self.report = report ?? ReportSendModel(record: record)
        self.defaults = defaults
        self.settings = settings
        self.dependencies = dependencies
        self.ledger = ledger
        self.open = open
        face = findings[0].action == .sendReport ? .report : .findings
        self.report.onFinish = { [weak self] never in self?.reportFinished(neverAskAgain: never) }
    }

    // MARK: - What the panel shows

    var headline: RunDiagnosis.Finding {
        findings[0]
    }

    /// The findings under the first.
    var others: [RunDiagnosis.Finding] {
        Array(findings.dropFirst())
    }

    /// A run whose first finding only offers the report opens on it, and its
    /// "Never ask again" is the crash report's.
    var opensOnReport: Bool {
        headline.action == .sendReport
    }

    /// Whether any finding here can be muted for this game.
    var canStopAsking: Bool {
        findings.contains { Preferences.quietAppsKey(for: $0.cause) != nil }
    }

    var isWorking: Bool {
        if case .working = progress { true } else { false }
    }

    // MARK: - The answers

    /// Takes a finding's action. The first finding's ends the panel; another's
    /// leaves it open on what is left.
    func perform(_ finding: RunDiagnosis.Finding) {
        switch finding.action {
        case let .apply(values, _, source):
            adopt(values, source: source, for: finding)
        case let .install(dependency, dll, _):
            install(dependency, dll: dll, for: finding)
        case let .open(guide, _):
            EventLog.enqueue(.client, "run finding \(finding.cause.rawValue) — \(record.appid): opened \(guide)")
            open(guide, record)
            done(with: finding)
        case .sendReport:
            face = .report
        case nil:
            done(with: finding)
        }
    }

    func showReport() {
        face = .report
    }

    /// Closes the panel with nothing taken, muting what it showed for this
    /// game when asked to.
    func notNow() {
        if stopsAsking {
            for finding in findings where !taken.contains(finding.cause) {
                Preferences.stopAsking(about: finding.cause, forApp: record.appid, in: defaults)
            }
        }
        installing?.cancel()
        onFinish?()
    }

    /// The close button and Escape: the answer that takes nothing.
    func dismiss() {
        switch face {
        case .findings: notNow()
        case .report: report.decline()
        }
    }

    // MARK: - Doing it

    private func adopt(_ values: ConfigValues, source: AppliedFixes.Source, for finding: RunDiagnosis.Finding) {
        write(values, source: source)
        EventLog.enqueue(
            .client,
            "run finding \(finding.cause.rawValue) — \(record.appid): set "
                + GameConfig.changes(from: .empty, to: values).joined(separator: ", "),
        )
        done(with: finding)
    }

    /// Writes `values` over the game's own and records them for Undo.
    private func write(_ values: ConfigValues, source: AppliedFixes.Source) {
        let appID = record.appid
        let recorded = ledger.flatMap { FixLedger.record(for: appID, in: $0) }
        var adopted: AppliedFixes?
        settings.update(.game(appID, bottle: SteamBottle.name)) { own in
            guard let planned = FixLedger.adopt(values, source: source, own: own, record: recorded) else { return }
            own = planned.values
            adopted = planned.record
        }
        if let adopted, let ledger { FixLedger.save(adopted, for: appID, in: ledger) }
    }

    private func install(_ dependency: String, dll: String, for finding: RunDiagnosis.Finding) {
        guard installing == nil else { return }
        let package = BottleDependencies.catalog.first { $0.id == dependency }
        let name = package?.name ?? dependency
        progress = .working(String(localized: "Installing \(name)…"))
        installing = Task(name: "Install \(dependency) for a run's finding") {
            defer { installing = nil }
            if package.map(dependencies.isInstalled) != true,
               let failure = await dependencies.install(dependency, phase: { _ in }) {
                progress = .failed(String(localized: "\(name) could not be installed: \(failure)"))
                EventLog.enqueue(.client, "run finding \(finding.cause.rawValue) — \(record.appid): \(dependency) failed: \(failure)")
                return
            }
            guard !Task.isCancelled else { return }
            let repair = KnownFixes.DLLRepair(dependency: dependency, dll: dll)
            write(
                ConfigValues(dllOverrides: [repair.dll: repair.mode]),
                source: AppliedFixes.Source(
                    title: name, reason: "A run on this Mac could not start without a library this package carries.",
                ),
            )
            EventLog.enqueue(.client, "run finding \(finding.cause.rawValue) — \(record.appid): \(dependency) installed, \(dll)=\(repair.mode)")
            progress = nil
            done(with: finding)
        }
    }

    private func done(with finding: RunDiagnosis.Finding) {
        taken.insert(finding.cause)
        if finding.cause == headline.cause { onFinish?() }
    }

    /// The report's flow ended, sent or not. A panel that opened on a finding
    /// whose action is still to take goes back to it.
    private func reportFinished(neverAskAgain: Bool) {
        if neverAskAgain { defaults.set(false, forKey: Preferences.asksAfterCrashKey) }
        if !opensOnReport, !taken.contains(headline.cause) {
            face = .findings
        } else {
            onFinish?()
        }
    }
}
