import AppKit
import Propofol
import SwiftUI

/// Settings › HoYoverse: the HoYoverse games Sevoflurane downloads and
/// updates from HoYoPlay's own servers, and installing a new one.
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
                HStack {
                    Spacer()
                    Button("Add Existing Folder…", action: addExisting)
                }
            } header: {
                Text("Games")
            } footer: {
                Text("""
                Updates come from the servers HoYoPlay uses, as patches when the game's build is recent enough \
                and as the changed files otherwise. Honkai: Star Rail is kept up to date but does not start \
                under Wine, so it is not added to Quick Launch.
                """)
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

/// One installation: its build, what it needs, and its actions.
private struct HoYoGameRow: View {
    let row: HoYoStore.Row
    let store: HoYoStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(row.installation.game.displayName)
                    Text(verbatim: row.installation.folder.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                actions
            }
            if let job = store.jobs[row.id] {
                HoYoProgressRow(job: job) { store.cancel(row.id) }
            } else {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let note = store.notes[row.id] {
                Text(note).font(.callout)
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
        case .download: String(localized: "\(installed) — \(plan.latest) is out; too old to patch, the changed files are downloaded (up to \(size))")
        }
    }
}

/// A running job's bar, what it is doing and how far it has come.
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
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
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

/// Installing a game into a new folder.
private struct HoYoInstallSection: View {
    let store: HoYoStore
    @State private var game = HoYoGame.genshin
    @State private var voices: Set<String> = ["en-us"]
    @State private var folder: URL?

    var body: some View {
        Section {
            Picker("Game", selection: $game) {
                ForEach(HoYoGame.allCases, id: \.self) { Text(verbatim: $0.displayName).tag($0) }
            }
            LabeledContent("Voice-over") {
                HStack {
                    ForEach(["en-us", "ja-jp", "zh-cn", "ko-kr"], id: \.self) { field in
                        Toggle(HoYoVoice.name(field), isOn: Binding(
                            get: { voices.contains(field) },
                            set: { on in if on { voices.insert(field) } else { voices.remove(field) } },
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
            LabeledContent("Folder") {
                HStack(spacing: 6) {
                    Text(verbatim: target.path)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(target.path)
                    Button("Choose…", action: choose)
                }
            }
            if let installing = store.installing, let job = store.jobs[installing.folder.standardizedFileURL.path] {
                VStack(alignment: .leading) {
                    Text("Installing \(installing.game.displayName)")
                    HoYoProgressRow(job: job) { store.cancel(installing.folder.standardizedFileURL.path) }
                }
            } else {
                HStack {
                    Spacer()
                    Button("Install") { store.startInstall(game, into: target, voices: voices.sorted()) }
                        .disabled(store.installing != nil)
                }
            }
            if let note = store.notes[target.standardizedFileURL.path], store.installing == nil,
               HoYoInstallation(folder: target) == nil {
                Text(note).font(.callout)
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

    /// The chosen folder, or one named after the game in ~/Games.
    private var target: URL {
        folder ?? FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Games")
            .appending(path: game.displayName.replacingOccurrences(of: ":", with: ""))
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
