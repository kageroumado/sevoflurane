import AppKit
import SwiftUI
import UniformTypeIdentifiers

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

    /// Starts a program through the daemon, which is the bottle's one parent.
    func launch(_ entry: AdoptedPrograms.Entry, renderer: Renderer? = nil) {
        guard simulated == nil else { return }
        ActivationPolicy.claimRightForALaunch()
        let query = renderer.map { "&renderer=\($0.rawValue)" } ?? ""
        Task(name: "Launch \(entry.name)") {
            let logOffset = KernelDriverFailure.size()
            // Long enough for a first launch that creates the companion
            // prefix of a program that needs a steam.exe parent (SteamParent).
            guard await DaemonService.post(
                "/program/launch?id=\(entry.id)\(query)", timeout: 240,
            ) != nil else {
                EventLog.shared.log(
                    .client,
                    "could not start \(entry.name): the background helper did not answer",
                )
                return
            }
            guard let driver = await KernelDriverFailure.watch(
                from: logOffset, program: entry.program.url.lastPathComponent,
            ) else { return }
            EventLog.shared.log(
                .client, "\(entry.name) showed no window; it tried to load the kernel driver \(driver), which Wine cannot load",
            )
            ModalAlerts.present { Self.explainKernelDriver(driver, program: entry.name) }
        }
    }

    /// A program that drew nothing after its kernel driver failed has no
    /// other way to say why, so the likely reason is said once.
    private static func explainKernelDriver(_ driver: String, program: String) {
        let alert = NSAlert()
        alert.messageText = String(localized: "\(program) showed no window")
        alert.informativeText = String(localized: """
        It tried to load \(driver), a Windows kernel driver, usually kernel-level anti-cheat, and kernel \
        drivers cannot run on a Mac. If the program requires it, that is why it stopped.
        """)
        alert.addButton(withTitle: String(localized: "OK"))
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
        refresh()
    }

    func showInFinder(_ entry: AdoptedPrograms.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([entry.program.url])
    }

    /// Asks for an executable and opens the adoption panel on it.
    func chooseProgram() {
        guard simulated == nil else { return }
        let panel = NSOpenPanel()
        panel.title = "Choose a Windows Program"
        panel.prompt = "Open"
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
