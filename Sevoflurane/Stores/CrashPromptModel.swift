import AppKit
import Foundation
import Observation

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

    static let offer = "Send the report to the Sevoflurane developers? It contains: this run's record and "
        + "settings, the game's own crash logs, and the app's, Wine's and Steam's logs, with paths, "
        + "account names and Steam ids removed."

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
    ///     app's is `sevo diag`'s builder narrowed to this run.
    ///   - upload: Where and as whom it is sent.
    ///   - report: The community report's model; the app's reads the sharing
    ///     preference and queues through ``StatsUploader``.
    init(
        record: RunRecord,
        bundle: (@Sendable (URL) async throws -> URL)? = nil,
        upload: ReportUpload = .forThisApp(),
        report: RunReportModel? = nil,
    ) {
        self.record = record
        self.bundle = bundle ?? { try await Diagnostics.bundle(to: $0, steamLogs: true, onlyRun: record) }
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
