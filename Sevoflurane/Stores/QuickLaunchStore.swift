import AppKit
import Observation
import UniformTypeIdentifiers

/// What a program's launch reports to: the Steam host's status line, window
/// watch and run record.
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

/// The adopted Windows programs for the menu bar, read from the settings
/// store on disk so the list works with no Steam client running.
@MainActor
@Observable
final class QuickLaunchStore {
    private(set) var programs: [AdoptedPrograms.Entry] = []
    @ObservationIgnored private var icons: [Int: NSImage] = [:]
    /// A fixed list for the gallery.
    @ObservationIgnored private let simulated: [AdoptedPrograms.Entry]?

    init(simulated: [AdoptedPrograms.Entry]? = nil) {
        self.simulated = simulated
        refresh()
    }

    /// Re-reads the store. A change found here came from outside the app
    /// (`sevo program`, the MCP server), so Steam's library is synced too.
    func refresh() {
        let next = simulated ?? AdoptedPrograms.all()
        guard next != programs else { return }
        programs = next
        if simulated == nil { SteamLibraryShortcuts.shared.sync() }
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

    /// A launch's steps, told to the Steam host.
    struct LaunchHooks {
        let pressed: @MainActor (Int) -> UUID?
        let started: @MainActor (Int) -> Void
        let ended: @MainActor (Int, UUID?) -> Void

        /// The steps told to `host`; every store that starts a program,
        /// popover or Dock tile, is wired this way.
        init(reporting host: some ProgramLaunchReporting) {
            pressed = { host.beginProgramLaunch(appID: $0) }
            started = { host.programDidStart(appID: $0) }
            ended = { host.endProgramLaunch(appID: $0, ticket: $1) }
        }
    }

    @ObservationIgnored var launchHooks: LaunchHooks?

    /// The programs whose launch request is with the helper, from the press
    /// to its reply. A second press on one of them is ignored: each press
    /// during a slow first companion launch would otherwise start another game.
    private(set) var launching: Set<Int> = []

    /// Where a launch was asked for: a Dock tile hears a refusal only as a notification.
    enum Origin {
        case popover
        case dock
    }

    /// Starts a program through the daemon, which is the bottle's one parent.
    func launch(_ entry: AdoptedPrograms.Entry, renderer: Renderer? = nil, origin: Origin = .popover) {
        guard simulated == nil, launching.insert(entry.id).inserted else { return }
        ActivationPolicy.claimRightForALaunch()
        let ticket = launchHooks?.pressed(entry.id) ?? nil
        let query = renderer.map { "&renderer=\($0.rawValue)" } ?? ""
        Task(name: "Launch \(entry.name)") {
            let logOffset = KernelDriverFailure.size()
            // Long enough for a first launch that creates a companion prefix (SteamParent).
            guard let reply = await DaemonService.postReply(
                "/program/launch?id=\(entry.id)\(query)", timeout: 240,
            ) else {
                EventLog.shared.log(
                    .client,
                    "could not start \(entry.name): the background helper did not answer",
                )
                if origin == .dock, let delegate = NSApp.delegate as? AppDelegate {
                    delegate.notifications.postLaunchDeclined(
                        name: entry.name, reason: String(localized: "The background helper did not answer."),
                    )
                }
                launching.remove(entry.id)
                launchHooks?.ended(entry.id, ticket)
                return
            }
            launching.remove(entry.id)
            guard (200 ..< 300).contains(reply.status) else {
                // 409: already starting or running, which the helper logs itself.
                if reply.status != 409 {
                    EventLog.shared.log(.client, "could not start \(entry.name): \(Self.reason(reply.data))")
                }
                if origin == .dock, let delegate = NSApp.delegate as? AppDelegate {
                    delegate.notifications.postLaunchDeclined(name: entry.name, reason: Self.reason(reply.data))
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
            // One alert per program at a time.
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

    /// Explains a program that drew nothing after its kernel driver failed.
    /// The app comes forward first: otherwise the alert opens behind the front
    /// app's windows and its modal session swallows the popover's clicks.
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

    /// Forgets a program and leaves its executable in place; installed files
    /// are removed from Settings › Storage.
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

    /// Renames a program's row, Steam shortcut and launcher bundle; a kept
    /// Dock tile follows the bundle.
    func rename(_ entry: AdoptedPrograms.Entry, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard simulated == nil, !name.isEmpty, name != entry.name else { return }
        // Read before the record changes the bundle's name.
        let old = GameLaunchers.dockableBundle(appID: entry.id)
        var values = GameConfig.game(entry.id)
        values.name = name
        GameConfig.setGame(entry.id, values)
        EventLog.shared.log(.setup, "renamed \(entry.name) to \(name)")
        SteamLibraryShortcuts.shared.sync()
        refresh()
        Task.detached(name: "Rebuild \(name)'s bundle") {
            ConfigMaterializer.materialize(bottle: SteamBottle.name, prefix: SteamBottle.root)
            if let old, let new = GameLaunchers.dockableBundle(appID: entry.id), old != new {
                DockTiles.replace(old, with: new)
            }
        }
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
