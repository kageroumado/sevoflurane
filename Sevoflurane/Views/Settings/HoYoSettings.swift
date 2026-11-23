import AppKit
import Propofol
import SwiftUI

/// Settings › HoYoverse: the HoYoverse games Sevoflurane installs and updates
/// from HoYoPlay's servers.
struct HoYoSettings: View {
    let highlighted: SettingsAnchor?
    var store = HoYoStore.shared

    var body: some View {
        Form {
            Section {
                if store.rows.isEmpty {
                    Text("No HoYoverse games yet. Install one below, or add the folder of one you already have.")
                        .foregroundStyle(.secondary)
                }
                ForEach(store.rows) { row in
                    HoYoGameRow(row: row, store: store)
                }
                SettingsRow {
                    Spacer()
                    Button("Add Existing Folder…", action: addExisting)
                }
            } header: {
                HStack(spacing: 6) {
                    Text("Games")
                    SettingHelpButton(help: .hoyoGames)
                }
            } footer: {
                Text("Honkai: Star Rail updates here but does not start under Wine.")
            }
            .highlightable(.hoyoverseGames, highlighted: highlighted)

            HoYoInstallSection(store: store)
                .highlightable(.hoyoverseInstall, highlighted: highlighted)
        }
        .formStyle(.grouped)
        .onAppear { store.reload() }
    }

    private func addExisting() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose a Game's Folder")
        panel.message = String(localized: "The folder the game's .exe is in.")
        panel.prompt = String(localized: "Add")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if !store.addExisting(url) {
            let alert = NSAlert()
            alert.messageText = String(localized: "No HoYoverse game in this folder")
            alert.informativeText = String(localized: "Choose the folder that holds GenshinImpact.exe, StarRail.exe or ZenlessZoneZero.exe.")
            alert.runModal()
        }
    }
}

private struct HoYoGameRow: View {
    let row: HoYoStore.Row
    let store: HoYoStore

    var body: some View {
        SettingsRow(caption: store.jobs[row.id] == nil ? store.notes[row.id] ?? status : "") {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                LabeledContent {
                    actions
                } label: {
                    Text(row.installation.game.displayName)
                        .help(row.installation.folder.path)
                }
                if let job = store.jobs[row.id] {
                    HoYoProgressRow(job: job) { store.cancel(row.id) }
                }
            }
        }
        .contextMenu {
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([row.installation.folder]) }
            Button("Stop Listing") { store.forget(row.id) }
                .disabled(store.jobs[row.id] != nil)
        }
    }

    @ViewBuilder private var actions: some View {
        let busy = store.jobs[row.id] != nil
        HStack(spacing: 6) {
            if let plan = row.plan, plan.kind != .upToDate {
                Button("Update") { store.startUpdate(row.id) }.disabled(busy)
            }
            if store.problems[row.id] != nil {
                Button("Repair") { store.startRepair(row.id) }.disabled(busy)
            }
            Button("Verify Files") { store.startVerify(row.id) }.disabled(busy)
        }
    }

    private var status: String {
        let installed = row.version ?? String(localized: "unknown build")
        if let failure = row.checkFailure {
            return String(localized: "\(installed) — could not reach HoYoPlay's servers: \(failure)")
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

private struct HoYoProgressRow: View {
    let job: HoYoStore.Job
    let cancel: () -> Void

    var body: some View {
        HStack {
            if let fraction = job.progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(caption).font(.callout).foregroundStyle(.secondary).monospacedDigit()
            if job.kind != .verify {
                Button("Stop", action: cancel).controlSize(.small)
            }
        }
    }

    private var caption: String {
        guard let progress = job.progress else { return String(localized: "Starting…") }
        let phase = switch progress.phase {
        case .preparing: String(localized: "Reading the build")
        case .checking: String(localized: "Checking files")
        case .downloading: String(localized: "Downloading")
        case .patching: String(localized: "Patching")
        case .finishing: String(localized: "Finishing")
        }
        guard progress.bytesTotal > 0 else { return phase }
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

    var body: some View {
        Section {
            SettingsRow {
                Picker("Game", selection: $game) {
                    ForEach(HoYoGame.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
                }
                .endsOnControlLine()
            }
            ActionRow(title: "Voice-over") {
                ForEach(["en-us", "ja-jp", "zh-cn", "ko-kr"], id: \.self) { field in
                    Toggle(HoYoVoice.name(field), isOn: Binding(
                        get: { voices.contains(field) },
                        set: { on in if on { voices.insert(field) } else { voices.remove(field) } },
                    ))
                    .toggleStyle(.checkbox)
                }
            }
            ActionRow(title: "Folder") {
                Text(verbatim: target.path)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(target.path)
                Button("Choose…", action: choose)
            }
            if let installing = store.installing, let job = store.jobs[installing.folder.standardizedFileURL.path] {
                SettingsRow {
                    VStack(alignment: .leading) {
                        Text("Installing \(installing.game.displayName)")
                        HoYoProgressRow(job: job) { store.cancel(installing.folder.standardizedFileURL.path) }
                    }
                }
            } else {
                SettingsRow(caption: installNote ?? "") {
                    Spacer()
                    Button("Install") { store.startInstall(game, into: target, voices: voices.sorted()) }
                        .disabled(store.installing != nil)
                }
            }
        } header: {
            Text("Install a game")
        } footer: {
            Text("""
            A game is around 100 GB and each voice-over another 12 to 15 GB. An install that stops, or is \
            stopped, carries on from where it was when you install into the same folder again.
            """)
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
