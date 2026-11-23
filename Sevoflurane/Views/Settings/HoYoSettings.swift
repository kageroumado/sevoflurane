import AppKit
import SwiftUI

/// Settings › HoYoverse: the HoYoverse games Sevoflurane installs and updates
/// from HoYoPlay's servers.
struct HoYoSettings: View {
    let highlighted: SettingsAnchor?
    var store = HoYoStore.shared

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            SettingsSection(
                title: "Games", anchor: .hoyoverseGames, help: .hoyoGames,
                footer: "Honkai: Star Rail updates here but does not start under Wine.",
            ) {
                if store.rows.isEmpty {
                    SettingsMessage(text: "No HoYoverse games yet.")
                }
                ForEach(store.rows) { row in
                    HoYoGameRow(row: row, store: store)
                }
                SettingsAction(title: "A game you already have") {
                    Button("Add Existing Folder…", action: addExisting)
                }
            }
            .highlightableSection(.hoyoverseGames, highlighted: highlighted)

            HoYoInstallSection(store: store)
                .highlightableSection(.hoyoverseInstall, highlighted: highlighted)
        }
        .onAppear { store.reload() }
    }

    private func addExisting() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Game\u{2019}s Folder")
        panel.message = String(localized: "The folder the game\u{2019}s .exe is in.")
        panel.prompt = String(localized: "Add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.addExisting(url) {
            let alert = NSAlert()
            alert.messageText = String(localized: "No HoYoverse game in this folder")
            alert.informativeText = String(localized: "Choose the folder that holds GenshinImpact.exe, StarRail.exe, or ZenlessZoneZero.exe.")
            alert.runModal()
        }
    }
}

private struct HoYoGameRow: View {
    let row: HoYoStore.Row
    let store: HoYoStore

    var body: some View {
        if let job = store.jobs[row.id] {
            HoYoProgressRow(job: job, title: row.installation.game.displayName) { store.cancel(row.id) }
                .help(row.installation.folder.path)
        } else {
            SettingsAction(title: "\(row.installation.game.displayName)", caption: store.notes[row.id] ?? status) {
                if let plan = row.plan, plan.kind != .upToDate {
                    Button("Update") { store.startUpdate(row.id) }
                }
                if store.problems[row.id] != nil {
                    Button("Repair") { store.startRepair(row.id) }
                }
                Button("Verify Files") { store.startVerify(row.id) }
            }
            .help(row.installation.folder.path)
            .contextMenu {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.installation.folder]) }
                Button("Stop Listing") { store.forget(row.id) }
            }
        }
    }

    private var status: String {
        let installed = row.version ?? String(localized: "unknown build")
        if let failure = row.checkFailure {
            return String(localized: "\(installed) — could not reach HoYoPlay\u{2019}s servers: \(failure)")
        }
        guard let plan = row.plan else { return String(localized: "\(installed) — checking for updates…") }
        let size = ByteCountFormatter.string(fromByteCount: plan.downloadSize, countStyle: .file)
        return switch plan.kind {
        case .upToDate: String(localized: "\(installed) — up to date")
        case .patch: String(localized: "\(installed) — \(plan.latest) is out, a patch of up to \(size)")
        case .download: String(localized: "\(installed) — \(plan.latest) is out, a download of up to \(size)")
        }
    }
}

/// A job under way on a game: its stage, how far it is, and the button that
/// stops it.
private struct HoYoProgressRow: View {
    let job: HoYoStore.Job
    let title: String
    let cancel: () -> Void

    var body: some View {
        SettingsProgress(
            title: title, fraction: job.progress?.fraction, caption: amounts,
            stop: job.kind == .verify ? nil : cancel,
        )
    }

    private var phase: String {
        guard let progress = job.progress else { return String(localized: "Starting…") }
        return switch progress.phase {
        case .preparing: String(localized: "Reading the build")
        case .checking: String(localized: "Checking files")
        case .downloading: String(localized: "Downloading")
        case .patching: String(localized: "Patching")
        case .finishing: String(localized: "Finishing")
        }
    }

    /// The stage, then how much of the total is done.
    private var amounts: String {
        guard let progress = job.progress, progress.bytesTotal > 0 else { return phase }
        let done = ByteCountFormatter.string(fromByteCount: progress.bytesDone, countStyle: .file)
        let total = ByteCountFormatter.string(fromByteCount: progress.bytesTotal, countStyle: .file)
        return "\(phase) \(done) / \(total)"
    }
}

private struct HoYoInstallSection: View {
    let store: HoYoStore
    @State private var game = HoYoGame.genshin
    @State private var voices: Set<String> = ["en-us"]
    @State private var folder: URL?

    private static let voiceFields = ["en-us", "ja-jp", "zh-cn", "ko-kr"]

    var body: some View {
        SettingsSection(
            title: "Install a game", anchor: .hoyoverseInstall,
            footer: "A game is around 100 GB and each voice-over another 12 to 15 GB. An install that stops, or is stopped, carries on from where it was when you install into the same folder again.",
        ) {
            SettingsPicker(title: "Game", selection: $game) {
                ForEach(HoYoGame.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            }
            SettingsChecks(
                title: "Voice-over",
                options: Self.voiceFields.map { ($0, HoYoVoice.name($0)) },
                selection: $voices,
            )
            SettingsAction(title: "Folder") {
                SettingsValueText(text: target.path)
                Button("Choose…", action: choose)
            }
            if let installing = store.installing, let job = store.jobs[installing.folder.standardizedFileURL.path] {
                HoYoProgressRow(job: job, title: String(localized: "Installing \(installing.game.displayName)")) {
                    store.cancel(installing.folder.standardizedFileURL.path)
                }
            } else {
                SettingsAction(title: "\(game.displayName)", caption: installNote ?? "") {
                    Button("Install Game") { store.startInstall(game, into: target, voices: voices.sorted()) }
                        .disabled(store.installing != nil)
                }
            }
        }
    }

    /// What the last install into the chosen folder left to say.
    private var installNote: String? {
        guard store.installing == nil, HoYoInstallation(folder: target) == nil else { return nil }
        return store.notes[target.standardizedFileURL.path]
    }

    /// The chosen folder, or one named after the game in ~/Games.
    private var target: URL {
        folder ?? store.defaultInstallFolder(for: game)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Where to Install")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        folder = url
    }
}
