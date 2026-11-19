import AppKit
import Propofol
import SwiftUI

/// Which endings deserve a word with the user, and how one run is told from its
/// neighbors; pure, so it is testable without a window.
nonisolated enum CrashPromptPolicy {
    /// A crash, the stall watchdog's kill, or an error exit while the game was
    /// starting.
    static func deserves(_ record: RunRecord) -> Bool {
        switch record.exit?.kind {
        case .crash, .watchdog: true
        case .exitError: quitWhileStarting(record)
        default: false
        }
    }

    /// An error exit before the game was up: under ``startingSeconds``, or under
    /// ``windowlessSeconds`` (or unmeasured) without ever showing a window. A
    /// game's own crash handler often ends this way; an error exit after play is
    /// how plenty of games quit.
    static func quitWhileStarting(_ record: RunRecord) -> Bool {
        guard record.exit?.kind == .exitError else { return false }
        if let duration = record.durationSeconds, duration < startingSeconds { return true }
        return record.windowAfterSeconds == nil && (record.durationSeconds ?? 0) < windowlessSeconds
    }

    /// How long a game is still starting, for ``quitWhileStarting(_:)``.
    static let startingSeconds: Double = 30
    static let windowlessSeconds: Double = 120

    /// A run's identity: its start and its app. The same run can close twice (a
    /// reattach, then the client's notification).
    static func key(for record: RunRecord) -> String {
        "\(record.t)/\(record.appid)"
    }
}

/// The offer after a crash: one panel per run, naming what stopped and what is
/// known about it, asking whether to send the report. A floating panel, since
/// the game that just died may have been the only window on screen.
@MainActor
final class CrashPrompt: NSObject, NSWindowDelegate {
    static let shared = CrashPrompt()

    private let defaults: UserDefaults
    private let presenter: ((RunRecord) -> Void)?
    private var offered: Set<String> = []
    private var panel: NSPanel?
    private var model: CrashPromptModel?

    /// - Parameters:
    ///   - defaults: Where "Never ask again" is read from and written to.
    ///   - presenter: What showing the prompt means. A test injects one; the
    ///     app opens the panel.
    init(defaults: UserDefaults = Preferences.shared, presenter: ((RunRecord) -> Void)? = nil) {
        self.defaults = defaults
        self.presenter = presenter
    }

    /// Points the recorder's closing hook at this prompt and, past it, the
    /// video-decoding and processor-limit offers; and the decoded-nothing hook
    /// at the video-decoding offer, which opens while the game still waits on
    /// its picture. The hooks fire on the recorder's queues.
    func install(spin: ThreadSpinPrompt = .shared, video: VideoDecodingPrompt = .shared) {
        RunRecorder.didClose = { [weak self] record in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.offerAfterClose(record, spin: spin, video: video) }
            }
        }
        RunRecorder.didStarveVideo = { record in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { video.offer(record, crashShown: false) }
            }
        }
    }

    /// A closed run gets one panel: the crash prompt when it earns one, else
    /// the video-decoding offer, else the processor-limit offer. A video offer
    /// that opened during the run counts as its one.
    func offerAfterClose(_ record: RunRecord, spin: ThreadSpinPrompt, video: VideoDecodingPrompt = .shared) {
        let crashShown = offer(record)
        let videoShown = video.offer(record, crashShown: crashShown)
        spin.offer(record, crashShown: crashShown || videoShown)
    }

    /// Considers a closed run, and answers whether it opened the prompt.
    @discardableResult
    func offer(_ record: RunRecord) -> Bool {
        guard CrashPromptPolicy.deserves(record), Preferences.asksAfterCrash(in: defaults) else { return false }
        let key = CrashPromptPolicy.key(for: record)
        guard !offered.contains(key) else { return false }
        offered.insert(key)
        if let presenter {
            presenter(record)
        } else {
            present(record)
        }
        return true
    }

    private func present(_ record: RunRecord) {
        let model = CrashPromptModel(record: record)
        model.onFinish = { [weak self] neverAskAgain in
            if neverAskAgain { Preferences.asksAfterCrash = false }
            self?.close()
        }
        self.model = model
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: CrashPromptView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 460, height: 220))
        panel.center()
        // The app has no activation of its own, so the panel would open behind
        // whatever the user was in.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        model = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 220),
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

    /// The close button is "Don't send".
    func windowShouldClose(_: NSWindow) -> Bool {
        model?.decline()
        return false
    }

    #if DEBUG
        /// Whether this launch asked for the offer on a fixture run
        /// (`SEVO_DEMO_CRASH=1` or `--demo-crash`). The panel, zip and upload
        /// are real; only the run is made up.
        static var wasRequestedAtLaunch: Bool {
            ProcessInfo.processInfo.environment["SEVO_DEMO_CRASH"] != nil
                || CommandLine.arguments.contains("--demo-crash")
        }

        /// Opens the offer on a crashed fixture run shaped like the recorder's.
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

/// What the prompt knows and does: the run, its known failure, and the three
/// answers.
@MainActor
@Observable
final class CrashPromptModel {
    enum Stage: Equatable {
        case asking
        case preparing
        case sending
        case sent
        /// The endpoint refused it; the zip stays where Finder can find it.
        case kept
        case failed(String)
    }

    /// Where the prompt writes its zip; a sent report leaves nothing behind.
    static let reportsDirectory = AppIdentity.supportFolder
        .appendingPathComponent("Reports")

    static let offer = "Send the report to the Sevoflurane developers? It contains: the run summary, "
        + "Wine's exception record, the game's own crash log, with paths and account names removed."

    let record: RunRecord
    let known: KnownFailures.Entry?
    /// The community report beside the crash report: Send queues it too when a
    /// verdict was picked.
    let report: RunReportModel
    var neverAskAgain = false
    private(set) var stage = Stage.asking
    private(set) var zip: URL?
    /// Called with the "Never ask again" choice when the panel is done.
    var onFinish: ((Bool) -> Void)?

    @ObservationIgnored private var preparing: Task<URL?, Never>?
    @ObservationIgnored private var sending: Task<Void, Never>?
    private let bundle: @Sendable (URL) async throws -> URL
    private let upload: ReportUpload

    /// - Parameters:
    ///   - bundle: Builds the zip into a directory and answers its path. The
    ///     app's is the same builder as `sevo diag`.
    ///   - upload: Where and as whom it is sent.
    ///   - report: The community report's model; the app's reads the sharing
    ///     preference and queues through ``StatsUploader``.
    init(
        record: RunRecord,
        bundle: @escaping @Sendable (URL) async throws -> URL = { try await Diagnostics.bundle(to: $0, steamLogs: true) },
        upload: ReportUpload = .forThisApp(),
        report: RunReportModel? = nil,
    ) {
        self.record = record
        self.bundle = bundle
        self.upload = upload
        self.report = report ?? RunReportModel(record: record)
        known = KnownFailures.match(record)
    }

    // MARK: - What the panel shows

    var title: String {
        let name = record.name ?? String(localized: "The game")
        return CrashPromptPolicy.quitWhileStarting(record)
            ? String(localized: "\(name) quit with an error while starting.")
            : String(localized: "\(name) stopped unexpectedly.")
    }

    /// The known failure's sentence and its fix, when this run matches one.
    var knownSentence: String? {
        known.map { [InterfaceCopy.localized($0.summary), $0.fix.map(InterfaceCopy.localized)]
            .compactMap(\.self).joined(separator: " ")
        }
    }

    var keptSentence: String {
        let name = zip?.lastPathComponent ?? String(localized: "the zip")
        return String(localized: "The report was not accepted. \(name) is kept in Finder for you to send another way.")
    }

    // MARK: - The three answers

    /// Builds the zip if it has not been, and shows it in Finder.
    func show() {
        Task(name: "Show the crash report") {
            guard let zip = await prepared() else { return }
            NSWorkspace.shared.activateFileViewerSelecting([zip])
        }
    }

    /// Trashes a zip built only to be shown, so declining leaves nothing in
    /// Reports.
    ///
    /// The close button lands here too. Once Send was pressed the zip is the
    /// user's: an upload under way finishes, and a refused or failed one stays
    /// in Reports, as the panel says.
    func decline() {
        let shownOnly = sending == nil && (stage == .asking || stage == .preparing)
        if shownOnly {
            let building = preparing
            Task(name: "Trash the declined crash report") {
                guard let zip = await building?.value else { return }
                try? FileManager.default.trashItem(at: zip, resultingItemURL: nil)
            }
            zip = nil
        }
        onFinish?(neverAskAgain)
    }

    /// Sends once. The community report is queued first, so a zip that fails to
    /// build or upload does not lose it.
    func send() {
        guard sending == nil else { return }
        if report.send() {
            EventLog.enqueue(.client, "community report queued — \(report.record.id) \(report.reported?.verdict.rawValue ?? "")")
        }
        sending = Task(name: "Send the crash report") {
            defer { sending = nil }
            guard let zip = await prepared() else { return }
            stage = .sending
            do {
                switch try await upload.send(zip) {
                case .accepted:
                    try? FileManager.default.trashItem(at: zip, resultingItemURL: nil)
                    self.zip = nil
                    stage = .sent
                    EventLog.enqueue(.client, "crash report sent — \(record.summary)")
                case let .refused(status):
                    stage = .kept
                    EventLog.enqueue(.client, "crash report refused (\(status)) — kept \(zip.lastPathComponent)")
                }
            } catch let ReportUpload.Failure.tooLarge(bytes) {
                stage = .kept
                EventLog.enqueue(.client, "crash report is \(bytes) bytes, over the cap — kept \(zip.lastPathComponent)")
            } catch {
                stage = .failed(String(localized: "The report could not be sent: \(error.localizedDescription)"))
            }
        }
    }

    func finish() {
        onFinish?(neverAskAgain)
    }

    /// The zip, built once on first use; concurrent callers wait on the same
    /// build, which runs off the main actor.
    private func prepared() async -> URL? {
        if let preparing { return await preparing.value }
        stage = .preparing
        let bundle = bundle
        let directory = Self.reportsDirectory
        let build = Task<URL?, Never>(name: "Build the crash report") {
            do {
                let built = try await Task.detached { try await bundle(directory) }.value
                zip = built
                stage = .asking
                return built
            } catch {
                stage = .failed(String(localized: "The report could not be written: \(error)"))
                preparing = nil
                return nil
            }
        }
        preparing = build
        return await build.value
    }
}

// MARK: - The view

private struct CrashPromptView: View {
    @Bindable var model: CrashPromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            if let known = model.knownSentence {
                Text(known)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            switch model.stage {
            case .asking:
                Text(InterfaceCopy.localized(CrashPromptModel.offer))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                howDidItGo
                Toggle("Never ask again", isOn: $model.neverAskAgain)
                    .font(.system(size: 11))
                choices
            case .preparing:
                progress("Gathering the logs…")
            case .sending:
                progress("Sending the report…")
            case .sent:
                Text("Sent. Thank you.")
                    .font(.system(size: 12))
                closing
            case .kept:
                Text(model.keptSentence)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show in Finder") { model.show() }
                    Spacer()
                    Button("Close") { model.finish() }
                        .keyboardShortcut(.defaultAction)
                }
            case let .failed(reason):
                Text(reason)
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                closing
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(model.record.displaySummary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    /// The community report's fields, or the one line saying where sharing is turned on.
    @ViewBuilder private var howDidItGo: some View {
        if let reported = model.report.reported {
            ReportedLine(reported: reported)
        } else if model.report.sharing {
            Text("How did it go? Sending also tells other Mac players, with the configuration below.")
                .font(.system(size: 12, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            RunReportFields(model: model.report)
        } else {
            Text(RunReportCard.sharingOffHint)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func progress(_ text: String) -> some View {
        HStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.small)
            Text(InterfaceCopy.localized(text))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        HStack(spacing: Theme.Space.sm) {
            Button(model.zip == nil ? "Show What Will Be Sent" : "Show in Finder") { model.show() }
            Spacer()
            Button("Don't Send") { model.decline() }
                .keyboardShortcut(.cancelAction)
            Button("Send") { model.send() }
                .keyboardShortcut(.defaultAction)
        }
    }

    private var closing: some View {
        HStack {
            Spacer()
            Button("Close") { model.finish() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
