import AppKit
import Propofol
import SwiftUI

/// Settings › Epic & GOG: signing in to each store, its Windows library,
/// and installing, updating, checking and removing its games, which then
/// start from Quick Launch like any other.
struct StoresSettings: View {
    let highlighted: SettingsAnchor?
    var store = StoresStore.shared
    @State private var selection = GameStore.epic
    @State private var filter = ""
    @State private var bases: [GameStore: URL] = [:]

    var body: some View {
        let account = store.account(selection)
        Form {
            Section {
                Picker("Store", selection: $selection) {
                    ForEach(GameStore.allCases) { Text(verbatim: $0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                StoreAccountRow(gameStore: selection, account: account, store: store)
            } footer: {
                StoreClientFooter(tool: selection.tool)
            }
            .highlightable(.storesAccount, highlighted: highlighted)

            if account.name != nil || !account.installs.isEmpty {
                Section("Installed") {
                    if account.installs.isEmpty {
                        Text("Nothing installed from \(selection.displayName) yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(account.installs) { install in
                        StoreInstallRow(install: install, update: account.updates[install.id], store: store)
                    }
                }
            }

            if account.name != nil {
                Section {
                    LabeledContent("Install in") {
                        HStack(spacing: 6) {
                            Text(verbatim: base.path)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(base.path)
                            Button("Choose…", action: chooseBase)
                        }
                    }
                    TextField("Filter", text: $filter, prompt: Text("Filter by name"))
                    ForEach(available(account)) { title in
                        StoreTitleRow(title: title, base: base, store: store)
                    }
                } header: {
                    HStack {
                        Text("Library")
                        Spacer()
                        if account.loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Button("Refresh") { store.reload(selection, force: true) }
                                .buttonStyle(.link)
                        }
                    }
                } footer: {
                    Text("""
                    The \(selection.displayName) games your account owns that run on Windows. Each one installs \
                    into a folder of its own and joins Quick Launch, with its own settings, Dock icon and run history.
                    """)
                }
                .highlightable(.storesLibrary, highlighted: highlighted)
            }
        }
        .formStyle(.grouped)
        .onAppear { store.reload(selection) }
        .onChange(of: selection) { _, new in store.reload(new) }
        .sheet(item: Binding(get: { store.signingIn }, set: { store.signingIn = $0 })) { gameStore in
            StoreSignInSheet(
                store: gameStore,
                onCode: { store.completeSignIn(gameStore, code: $0) },
                onCancel: { store.signingIn = nil },
            )
        }
    }

    /// The titles not installed yet, narrowed by the filter.
    private func available(_ account: StoresStore.Account) -> [StoreTitle] {
        let installed = Set(account.installs.map(\.id))
        let query = filter.trimmingCharacters(in: .whitespaces)
        return account.library.filter { title in
            !installed.contains(title.id) && (query.isEmpty || title.title.localizedStandardContains(query))
        }
    }

    private var base: URL {
        bases[selection] ?? selection.defaultInstallBase
    }

    private func chooseBase() {
        let panel = NSOpenPanel()
        panel.title = String(localized: "Choose Where to Install")
        panel.prompt = String(localized: "Choose")
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = base
        guard panel.runModal() == .OK, let url = panel.url else { return }
        bases[selection] = url
    }
}

/// Who is signed in, or the button that signs in.
private struct StoreAccountRow: View {
    let gameStore: GameStore
    let account: StoresStore.Account
    let store: StoresStore

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                if let name = account.name {
                    Text("Signed in as \(name)")
                    Spacer()
                    Button("Sign Out") { store.signOut(gameStore) }
                } else if account.client == .downloading {
                    Text("Downloading \(gameStore.tool.rawValue)…")
                    Spacer()
                    ProgressView().controlSize(.small)
                } else if account.loading {
                    Text("Reading your account…")
                    Spacer()
                    ProgressView().controlSize(.small)
                } else {
                    Text("Sign in to install your \(gameStore.displayName) games.")
                    Spacer()
                    Button("Sign In…") { store.beginSignIn(gameStore) }
                }
            }
            if let failure = account.failure {
                Text(failure).font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

/// The client a store goes through: its name, version, license and source.
private struct StoreClientFooter: View {
    let tool: StoreTool

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            Text("""
            Sevoflurane reaches the store through \(tool.rawValue) \(tool.version) from the Heroic Games Launcher \
            project, licensed under the \(StoreTool.license). It is downloaded from that project's release the first \
            time you sign in, checked against a fixed digest, and runs as a program of its own.
            """)
            Link("\(tool.rawValue) source \(Image(systemName: "arrow.up.right"))", destination: tool.source)
        }
    }
}

/// A title's box art, or a blank tile until it loads.
private struct StoreArt: View {
    let url: URL?

    var body: some View {
        AsyncImage(url: url) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            Rectangle().fill(.quaternary)
        }
        .frame(width: 64, height: 36)
        .clipShape(.rect(cornerRadius: 4))
    }
}

/// An installed game: its build, what it needs, and its actions.
private struct StoreInstallRow: View {
    let install: StoreInstall
    let update: String?
    let store: StoresStore

    var body: some View {
        let running = store.jobs[install.store]
        let mine = running?.id == install.id ? running?.job : nil
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                StoreArt(url: art)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: install.title)
                    Text(status).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 6) {
                    if update != nil {
                        Button("Update") { store.update(install) }
                    }
                    Button("Verify Files") { store.repair(install) }
                }
                .disabled(running != nil)
            }
            if let mine {
                StoreJobRow(job: mine) { store.cancel(install.store) }
            }
            if let note = store.notes[StoresStore.key(install.store, install.id)] {
                Text(note).font(.callout)
            }
        }
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: install.path)])
            }
            Button("Uninstall…", action: confirmUninstall)
                .disabled(running != nil)
        }
    }

    private var art: URL? {
        store.account(install.store).library.first { $0.id == install.id }?.art
    }

    private var status: String {
        var parts = [install.versionName ?? install.version]
        if let size = install.size, size > 0 {
            parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
        }
        if let update {
            parts.append(String(localized: "\(update) is out"))
        }
        return parts.joined(separator: " · ")
    }

    private func confirmUninstall() {
        let alert = NSAlert()
        alert.messageText = String(localized: "Uninstall \(install.title)?")
        alert.informativeText = String(localized: "Its folder goes to the Trash and it leaves Quick Launch. Saves the game keeps in its own folder go with it.")
        alert.addButton(withTitle: String(localized: "Uninstall"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.uninstall(install)
    }
}

/// A title the account owns and has not installed.
private struct StoreTitleRow: View {
    let title: StoreTitle
    let base: URL
    let store: StoresStore

    var body: some View {
        let running = store.jobs[title.store]
        let mine = running?.id == title.id ? running?.job : nil
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                StoreArt(url: title.art)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: title.title)
                    Text(size).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if mine == nil {
                    Button("Install") { store.install(title, into: base) }
                        .disabled(running != nil)
                }
            }
            if let mine {
                StoreJobRow(job: mine) { store.cancel(title.store) }
            }
            if let note = store.notes[StoresStore.key(title.store, title.id)] {
                Text(note).font(.callout)
            }
        }
        .task(id: title.id) { store.requestSize(title) }
    }

    private var size: String {
        guard let bytes = store.sizes[StoresStore.key(title.store, title.id)] else { return " " }
        return String(localized: "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) on disk")
    }
}

/// A running job's bar, what it is doing and how far it has come.
private struct StoreJobRow: View {
    let job: StoresStore.Job
    let cancel: () -> Void

    var body: some View {
        HStack {
            if let fraction = job.progress?.fraction {
                ProgressView(value: fraction)
            } else {
                ProgressView().controlSize(.small)
            }
            Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            if job.kind != .uninstall {
                Button("Stop", action: cancel).controlSize(.small)
            }
        }
    }

    private var caption: String {
        let phase = switch (job.kind, job.progress?.phase) {
        case (.uninstall, _): String(localized: "Removing")
        case (_, .checking?): String(localized: "Checking files")
        case (_, .downloading?): String(localized: "Downloading")
        case (_, nil): String(localized: "Starting…")
        }
        guard let progress = job.progress else { return phase }
        if let done = progress.bytesDone, let total = progress.bytesTotal {
            let doneText = ByteCountFormatter.string(fromByteCount: done, countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(phase) \(doneText) / \(totalText)"
        }
        if progress.phase == .downloading, let total = job.downloadSize {
            let doneText = ByteCountFormatter.string(fromByteCount: Int64(Double(total) * progress.fraction), countStyle: .file)
            let totalText = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
            return "\(phase) \(doneText) / \(totalText)"
        }
        return "\(phase) \(Int(progress.fraction * 100))%"
    }
}
