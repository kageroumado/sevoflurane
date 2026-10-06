import AppKit
import Propofol
import SwiftUI

/// The window that opens when a Windows program is handed to Sevoflurane —
/// dropped on the app, opened with it from Finder, or picked from the menu
/// bar.
///
/// A floating panel rather than a window: the app is a menu-bar agent with no
/// windows of its own, and this is one question with three answers.
@MainActor
final class AdoptionPanel {
    static let shared = AdoptionPanel()

    private var panel: NSPanel?

    /// Shows the panel for one executable, replacing whatever it was showing.
    func present(_ url: URL) {
        let model = AdoptionModel(url: url)
        model.onFinish = { [weak self] in self?.close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: AdoptionView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 260))
        panel.center()
        // An agent app has no activation of its own, so the panel would open
        // behind whatever the user was in.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false,
        )
        panel.title = String(localized: "Open in Sevoflurane")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

/// What the adoption panel knows and does: the file's own description of
/// itself, the verdict, and the four things that can be done with it.
@MainActor
@Observable
final class AdoptionModel {
    /// Where the panel is in the two-step installer flow.
    enum Stage: Equatable {
        /// Waiting for the user to pick what to do.
        case choosing
        /// The installer is running in the bottle.
        case installing
        /// It finished; these are the game-like executables it left behind.
        case installed(root: URL?, executables: [URL])
        /// It could not be started or it ended badly.
        case failed(String)
    }

    let url: URL
    let info: PEResources.Info?
    /// The program's own icon, shaped the way macOS shapes an app's. Drawn
    /// once: it is a PE resource read and a 256-pixel render.
    let icon: NSImage?
    private(set) var verdict: ProgramDetection.Verdict
    private(set) var stage = Stage.choosing
    /// Whether the user overruled an installer verdict for this file.
    private(set) var isOverruled = false
    /// Whether an overruled verdict is remembered for the next time this file
    /// is opened.
    var remembersOverrule = true
    /// The name the record will carry, which the user may correct.
    var name: String
    /// Executables from an install the user has chosen to keep.
    var chosen: Set<URL> = []

    /// Whether one executable from the install is ticked to keep.
    subscript(keeps exe: URL) -> Bool {
        get { chosen.contains(exe) }
        set {
            if newValue { chosen.insert(exe) } else { chosen.remove(exe) }
        }
    }

    /// Called when the panel has nothing left to ask.
    var onFinish: (() -> Void)?

    init(url: URL) {
        self.url = url
        let info = PEResources.read(url)
        self.info = info
        icon = Self.shapedIcon(of: info)
        verdict = ProgramDetection.classify(url)
        name = AdoptedPrograms.suggestedName(for: url)
    }

    // MARK: - What the panel shows

    private static func shapedIcon(of info: PEResources.Info?) -> NSImage? {
        guard let artwork = info?.largestIcon.flatMap(PEResources.image(of:)),
              let shaped = IconShaping.rendered(artwork, pixels: 256) else { return nil }
        return NSImage(cgImage: shaped, size: NSSize(width: 128, height: 128))
    }

    /// The version resource's one line: what the file calls itself, and which
    /// build it is.
    var subtitle: String? {
        let described = info?.productName ?? info?.fileDescription
        let version = info?.fileVersion
        return [described, version].compactMap(\.self)
            .filter { !$0.isEmpty && $0 != name }
            .joined(separator: " · ")
            .nilWhenEmpty
    }

    /// Where a launch would happen.
    var destination: String {
        String(localized: "Runs in the \(SteamBottle.name) bottle on \(Engine.active.description).")
    }

    var isInstaller: Bool {
        verdict.kind == ProgramKind.installer
    }

    // MARK: - What the panel does

    /// The user's word that this file is a program: its launcher, or the game
    /// itself. The verdict is read again without the installer signals, so a
    /// game's own signals still name it a game.
    func overruleInstaller() {
        isOverruled = true
        verdict = ProgramDetection.classify(url, notInstallers: [url.standardizedFileURL.path])
        EventLog.shared.log(.setup, "\(url.lastPathComponent): the user says it is not an installer")
    }

    /// Stores the overrule once the user acts on it, as they asked.
    private func rememberOverrule() {
        guard isOverruled, remembersOverrule else { return }
        ProgramDetection.markNotInstaller(url)
    }

    /// Records the program, and starts it when asked.
    func adopt(andPlay play: Bool) {
        rememberOverrule()
        let id = AdoptedPrograms.adopt(
            exe: url, name: trimmedName, kind: verdict.kind, bottle: SteamBottle.name,
        )
        EventLog.shared.log(.setup, "added \(trimmedName) to Quick Launch")
        SteamLibraryShortcuts.shared.sync()
        if play { launch(id) }
        onFinish?()
    }

    /// Starts the program once, keeping no record of it.
    func playOnce() {
        rememberOverrule()
        Task(name: "Run \(url.lastPathComponent) once") {
            await Self.runOnce(url, wait: false)
        }
        onFinish?()
    }

    /// Runs the installer to completion, then reports what it added.
    func install() {
        stage = .installing
        Task(name: "Install \(url.lastPathComponent)") {
            let before = Self.topLevelDirectories()
            let result = await Self.runOnce(url, wait: true)
            let added = Self.topLevelDirectories().subtracting(before)
            guard result else {
                stage = .failed(InterfaceCopy.localized("The installer did not start."))
                return
            }
            let root = added.sorted { $0.path < $1.path }.first
            let executables = added
                .flatMap { GameExecutables.executableURLs(in: $0) }
                .sorted { $0.path.count < $1.path.count }
            EventLog.shared.log(
                .setup,
                "\(url.lastPathComponent) finished; \(added.count) new "
                    + "director\(added.count == 1 ? "y" : "ies") in the bottle",
            )
            stage = .installed(root: root, executables: executables)
        }
    }

    /// Keeps the executables ticked in the second step.
    func adoptChosen(installedRoot: URL?) {
        for exe in chosen {
            AdoptedPrograms.adopt(
                exe: exe, kind: ProgramKind.game, bottle: SteamBottle.name,
                installedRoot: installedRoot?.path,
            )
        }
        EventLog.shared.log(.setup, "added \(chosen.count) installed program(s) to Quick Launch")
        SteamLibraryShortcuts.shared.sync()
        onFinish?()
    }

    func cancel() {
        onFinish?()
    }

    private var trimmedName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? url.deletingPathExtension().lastPathComponent : trimmed
    }

    private func launch(_ id: Int) {
        Task(name: "Launch adopted program \(id)") {
            await DaemonService.post("/program/launch?id=\(id)")
        }
    }

    /// One run through the daemon, which is the only process that parents a
    /// bottle process. An installer is waited for, because what it leaves on
    /// disk is the answer; anything else is started and let go.
    private static func runOnce(_ url: URL, wait: Bool) async -> Bool {
        let body = Data((url.standardizedFileURL.path + "\n").utf8)
        let route = wait ? "/program/run?timeout=3600" : "/program/run?wait=0"
        return await DaemonService.post(route, body: body, timeout: wait ? 3700 : 20) != nil
    }

    /// The directories an installer could add to: the drive's own root, both
    /// program folders, and the per-user application data.
    static func installRoots() -> [URL] {
        let drive = SteamBottle.root.appendingPathComponent("drive_c")
        return [
            drive,
            drive.appendingPathComponent("Program Files"),
            drive.appendingPathComponent("Program Files (x86)"),
            drive.appendingPathComponent("users/\(SteamBottle.windowsUser)/AppData/Local"),
        ]
    }

    /// Every directory directly inside the install roots, which is the
    /// before-and-after an installer is judged by.
    private static func topLevelDirectories() -> Set<URL> {
        var result: Set<URL> = []
        for root in installRoots() {
            for entry in InstallDirectory.entries(in: root) where entry.isDirectory {
                result.insert(entry.url)
            }
        }
        return result
    }
}

private extension String {
    var nilWhenEmpty: String? {
        isEmpty ? nil : self
    }
}

// MARK: - The view

/// The panel's contents: what the file is, where it would run, and the
/// choice.
private struct AdoptionView: View {
    @Bindable var model: AdoptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            switch model.stage {
            case .choosing:
                Text(model.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model.isOverruled {
                    Toggle("Remember for this file", isOn: $model.remembersOverrule)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                choices
            case .installing:
                progress
            case let .installed(root, executables):
                InstalledStep(model: model, root: root, executables: executables)
            case let .failed(reason):
                Text(reason).font(.system(size: 12)).foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("Close") { model.cancel() }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Group {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(model.verdict.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var progress: some View {
        HStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.small)
            Text("Installing into the bottle. The next step lists what was added.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isInstaller {
                Button("Not an Installer") { model.overruleInstaller() }
                    .help("Choose whether to play it once or add it to Quick Launch.")
                Button("Run Once") { model.playOnce() }
                Button("Install into Bottle") { model.install() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Play Once") { model.playOnce() }
                Button("Add to Quick Launch") { model.adopt(andPlay: false) }
                Button("Add and Play") { model.adopt(andPlay: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The installer's second step: what it left in the bottle, and which of it
/// is worth a Quick Launch entry.
private struct InstalledStep: View {
    @Bindable var model: AdoptionModel
    let root: URL?
    let executables: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !executables.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(executables, id: \.self) { exe in
                            Toggle(isOn: $model[keeps: exe]) {
                                Text(exe.lastPathComponent).font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Button("Close") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add to Quick Launch") { model.adoptChosen(installedRoot: root) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosen.isEmpty)
            }
        }
    }

    private var summary: String {
        guard let root else { return InterfaceCopy.localized("Sevoflurane found nothing the installer added.") }
        return executables.isEmpty
            ? String(localized: "It installed \(root.lastPathComponent). No program inside it can start.")
            : String(localized: "It installed \(root.lastPathComponent). Pick what to keep.")
    }
}
