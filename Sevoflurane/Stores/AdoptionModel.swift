import AppKit
import Foundation
import Observation

/// What the adoption panel knows and does: the file's own description, the
/// verdict, and the actions on it.
@MainActor
@Observable
final class AdoptionModel {
    /// Where the panel is in the two-step installer flow.
    enum Stage: Equatable {
        case choosing
        case installing
        /// Finished, with the game-like executables it left behind.
        case installed(root: URL?, executables: [URL])
        case failed(String)
    }

    let url: URL
    let info: PEResources.Info?
    /// The program's own icon, shaped as macOS shapes an app's. Drawn once: it
    /// is a PE resource read and a 256-pixel render.
    let icon: NSImage?
    private(set) var verdict: ProgramDetection.Verdict
    private(set) var stage = Stage.choosing
    /// Whether the user overruled an installer verdict for this file.
    private(set) var isOverruled = false
    /// Whether an overruled verdict is remembered for this file.
    var remembersOverrule = true
    /// The record's name, which the user may correct.
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

    /// The panel's heading: the name as the user has it now, or the file's.
    var title: String {
        trimmedName
    }

    /// The program's own version, shown beside the name.
    var version: String? {
        info?.fileVersion?.trimmingCharacters(in: .whitespacesAndNewlines).nilWhenEmpty
    }

    /// The file itself, which the name and icon above are not: both come
    /// from inside the program, and a download can call itself anything.
    var location: String {
        let folder = (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        return String(localized: "\(url.lastPathComponent) in \(folder)")
    }

    var destination: String {
        String(localized: "Runs in the \(SteamBottle.name) bottle on \(Engine.active.description).")
    }

    var isInstaller: Bool {
        verdict.kind == ProgramKind.installer
    }

    // MARK: - What the panel does

    /// The user's word that this file is a program rather than an installer.
    /// The verdict is read again without the installer signals, so a game's own
    /// signals still name it a game.
    func overruleInstaller() {
        isOverruled = true
        verdict = ProgramDetection.classify(url, notInstallers: [url.standardizedFileURL.path])
        EventLog.shared.log(.setup, "\(url.lastPathComponent): the user says it is not an installer")
    }

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

    /// One run through the daemon, the only process that parents a bottle
    /// process. An installer is waited for, because what it leaves on disk is
    /// the answer.
    private static func runOnce(_ url: URL, wait: Bool) async -> Bool {
        let body = Data((url.standardizedFileURL.path + "\n").utf8)
        let route = wait ? "/program/run?timeout=3600" : "/program/run?wait=0"
        return await DaemonService.post(route, body: body, timeout: wait ? 3700 : 20) != nil
    }

    /// The directories an installer could add to: the drive root, both program
    /// folders, and per-user application data.
    static func installRoots() -> [URL] {
        let drive = SteamBottle.root.appendingPathComponent("drive_c")
        return [
            drive,
            drive.appendingPathComponent("Program Files"),
            drive.appendingPathComponent("Program Files (x86)"),
            drive.appendingPathComponent("users/\(SteamBottle.windowsUser)/AppData/Local"),
        ]
    }

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
