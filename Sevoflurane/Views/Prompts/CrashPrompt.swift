import AppKit
import Propofol
import SwiftUI

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
