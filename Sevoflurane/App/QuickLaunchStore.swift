import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// What a program's launch reports to, beat by beat: the Steam host, which
/// carries the status line and opens the window watch and the run record
/// (``SteamWebHost/beginProgramLaunch(appID:)``).
@MainActor
protocol ProgramLaunchReporting: AnyObject {
    /// The ticket of the status line this press opened, or nil when a
    /// launch of the program already owns it.
    func beginProgramLaunch(appID: Int) -> UUID?
    func programDidStart(appID: Int)
    /// Ends the line only for the press that opened it.
    func endProgramLaunch(appID: Int, ticket: UUID?)
}

extension SteamWebHost: ProgramLaunchReporting {}

/// The adopted Windows programs as the menu bar reads them: the list, the
/// icon for each row, and the four things a row can do.
///
/// The Steam library in the popover comes from the client's own page over
/// CDP; this list comes from the settings store on disk, so it answers with
/// no client running and survives a client that never comes up.
@MainActor
@Observable
final class QuickLaunchStore {
    private(set) var programs: [AdoptedPrograms.Entry] = []
    /// Icons are read from disk, so each one is kept once it is drawn.
    @ObservationIgnored private var icons: [Int: NSImage] = [:]
    /// A fixed list posed for the gallery, which draws every surface on a
    /// machine that has none of them.
    @ObservationIgnored private let simulated: [AdoptedPrograms.Entry]?

    init(simulated: [AdoptedPrograms.Entry]? = nil) {
        self.simulated = simulated
        refresh()
    }

    /// Re-reads the store. Cheap: one directory listing and a JSON file per
    /// program.
    func refresh() {
        let next = simulated ?? AdoptedPrograms.all()
        guard next != programs else { return }
        programs = next
    }

    /// The program's own artwork, shaped like a macOS icon.
    func icon(for entry: AdoptedPrograms.Entry) -> NSImage? {
        if let cached = icons[entry.id] { return cached }
        guard simulated == nil else { return nil }
        guard let icns = GameIcon.shapedICNS(
            forProgramAt: entry.program.url, named: String(entry.id),
        ), let image = NSImage(contentsOf: icns) else { return nil }
        icons[entry.id] = image
        return image
    }

    /// The launch story's beats, told to the Steam host
    /// (``SteamWebHost/beginProgramLaunch(appID:)``): the row's status line,
    /// then the window watch and the run record once the helper has spawned
    /// the program, or the status cleared when it spawned nothing.
    struct LaunchHooks {
        let pressed: @MainActor (Int) -> UUID?
        let started: @MainActor (Int) -> Void
        let ended: @MainActor (Int, UUID?) -> Void

        /// The beats told to `host`. Every store that starts a program is
        /// wired this way — the popover's, and the one a Dock tile's launch
        /// uses before the menu bar exists — so a launch from anywhere opens
        /// the same status line, window watch and run record.
        init(reporting host: some ProgramLaunchReporting) {
            pressed = { host.beginProgramLaunch(appID: $0) }
            started = { host.programDidStart(appID: $0) }
            ended = { host.endProgramLaunch(appID: $0, ticket: $1) }
        }
    }

    @ObservationIgnored var launchHooks: LaunchHooks?

    /// The programs whose launch request is with the helper, from the press
    /// to its reply. A second press on one of them is the same wish again,
    /// not a second launch: five presses during a first companion launch
    /// made five games, 2026-09-26.
    private(set) var launching: Set<Int> = []

    /// Starts a program through the daemon, which is the bottle's one parent.
    func launch(_ entry: AdoptedPrograms.Entry, renderer: Renderer? = nil) {
        guard simulated == nil, launching.insert(entry.id).inserted else { return }
        ActivationPolicy.claimRightForALaunch()
        let ticket = launchHooks?.pressed(entry.id) ?? nil
        let query = renderer.map { "&renderer=\($0.rawValue)" } ?? ""
        Task(name: "Launch \(entry.name)") {
            let logOffset = KernelDriverFailure.size()
            // Long enough for a first launch that creates the companion
            // prefix of a program that needs a steam.exe parent (SteamParent).
            guard let reply = await DaemonService.postReply(
                "/program/launch?id=\(entry.id)\(query)", timeout: 240,
            ) else {
                EventLog.shared.log(
                    .client,
                    "could not start \(entry.name): the background helper did not answer",
                )
                launching.remove(entry.id)
                launchHooks?.ended(entry.id, ticket)
                return
            }
            // The request is answered; what follows is the program's own
            // story, and a press now is a new wish the helper judges.
            launching.remove(entry.id)
            guard (200 ..< 300).contains(reply.status) else {
                // 409 is the helper declining a program that is starting or
                // running already, which its log line says; anything else is
                // a failure, said here with the helper's reason.
                if reply.status != 409 {
                    EventLog.shared.log(.client, "could not start \(entry.name): \(Self.reason(reply.data))")
                }
                launchHooks?.ended(entry.id, ticket)
                return
            }
            launchHooks?.started(entry.id)
            guard let driver = await KernelDriverFailure.watch(
                from: logOffset, program: entry.program.url.lastPathComponent,
            ) else { return }
            EventLog.shared.log(
                .client, "\(entry.name) showed no window; it tried to load the kernel driver \(driver), which Wine cannot load",
            )
            // One alert per program at a time: every launch that failed the
            // same way while one is up says nothing the first does not.
            guard Self.explaining.insert(entry.name).inserted else { return }
            ModalAlerts.present {
                Self.explainKernelDriver(driver, program: entry.name)
                Self.explaining.remove(entry.name)
            }
        }
    }

    /// The programs whose kernel-driver alert is up.
    private static var explaining: Set<String> = []

    /// The reason in a helper refusal, whose body is `"<status> <reason>"`.
    private static func reason(_ body: Data) -> String {
        let text = String(decoding: body, as: UTF8.self)
        guard let space = text.firstIndex(of: " ") else { return text }
        return String(text[text.index(after: space)...])
    }

    /// A program that drew nothing after its kernel driver failed has no
    /// other way to say why, so the likely reason is said once.
    ///
    /// The app comes forward first. It runs as a menu bar app, so an alert
    /// raised while another app is in front opened behind that app's
    /// windows, and its modal session took every click and hover the popover
    /// got until someone found it, 2026-09-26.
    private static func explainKernelDriver(_ driver: String, program: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(program) showed no window")
        alert.informativeText = String(localized: """
        It tried to load \(driver), a Windows kernel driver, usually kernel-level anti-cheat, and kernel \
        drivers cannot run on a Mac. If the program requires it, that is why it stopped.
        """)
        alert.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        alert.window.level = .floating
        alert.runModal()
    }

    /// Forgets a program. The executable it points at is the user's and is
    /// left where it is; what an installer put in the bottle is removed from
    /// Settings › Storage, which can say how big it is first.
    func remove(_ entry: AdoptedPrograms.Entry) {
        guard simulated == nil else { return }
        AdoptedPrograms.remove(entry.id)
        icons[entry.id] = nil
        EventLog.shared.log(.setup, "removed \(entry.name) from Quick Launch")
        SteamLibraryShortcuts.shared.sync()
        refresh()
    }

    /// Lists a program in Steam's library as a non-Steam game, or takes it out.
    func setInSteamLibrary(_ listed: Bool, for entry: AdoptedPrograms.Entry) {
        guard simulated == nil else { return }
        SteamLibraryShortcuts.shared.setListed(listed, programID: entry.id)
        refresh()
    }

    func showInFinder(_ entry: AdoptedPrograms.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.program.url])
    }

    /// Asks for an executable and opens the adoption panel on it.
    func chooseProgram() {
        guard simulated == nil else { return }
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Windows Program")
        panel.prompt = String(localized: "Open")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let exe = UTType("com.microsoft.windows-executable") {
            panel.allowedContentTypes = [exe]
        }
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AdoptionPanel.shared.present(url)
    }
}
