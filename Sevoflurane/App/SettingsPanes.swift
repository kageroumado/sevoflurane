import Propofol
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettings: View {
    let provisioner: Provisioner
    let store: StorageStore
    let highlighted: String?
    /// The supervisor to stand down before an uninstall; `nil` in previews.
    var supervisor: ClientSupervisor?
    @State private var openAtLogin = false
    @State private var cliInstalled = false
    @State private var cliBusy = false
    @State private var cliError: String?
    @State private var agents: [AgentRow] = []
    @State private var confirmingUninstall = false

    /// One detected AI assistant: its registration state, and the in-flight
    /// and failure state of the last flip.
    private struct AgentRow: Identifiable {
        let harness: AgentIntegration.Harness
        var registered: Bool
        var busy = false
        var error: String?
        var id: String { harness.id }
    }

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $openAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("Sevoflurane starts in the menu bar. No windows until you ask.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: openAtLogin) { _, enabled in
                    provisioner.setOpenAtLogin(enabled)
                }
                .highlightable(id: "general.openAtLogin", highlighted: highlighted)
            }
            Section {
                cliRow
                if cliInstalled {
                    if agents.isEmpty {
                        Text("No supported AI assistants detected.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach($agents) { $row in
                            agentRow($row)
                        }
                    }
                    manualCommandRow
                }
            } header: {
                Text("Automation")
            } footer: {
                if cliInstalled {
                    Text("Each switch writes one entry into that assistant's "
                        + "own configuration and nothing else; turning it off "
                        + "removes exactly that entry.")
                }
            }
            uninstallSection
        }
        .formStyle(.grouped)
        .onAppear {
            openAtLogin = provisioner.openAtLogin
            cliInstalled = AgentIntegration.isCLIInstalled
            refreshAgents()
        }
        .task { await store.measure() }
    }

    // MARK: - Automation

    private var cliRow: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Command-line tool")
                Text(cliInstalled
                    ? "Installed at /usr/local/bin/sevo — a link into the "
                    + "app, so updates never ask again. Connect assistants "
                    + "below."
                    : "Puts sevo on your PATH so AI assistants can drive "
                    + "Steam over MCP. Asks for an administrator password "
                    + "once.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let cliError {
                    Text(cliError).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            if cliBusy {
                ProgressView().controlSize(.small)
            }
            Button(cliInstalled ? "Remove" : "Install…") {
                cliBusy = true
                Task {
                    if cliInstalled {
                        await AgentIntegration.remove()
                        cliError = nil
                    } else {
                        cliError = await AgentIntegration.installCLI()
                    }
                    cliInstalled = AgentIntegration.isCLIInstalled
                    refreshAgents()
                    cliBusy = false
                }
            }
            .disabled(cliBusy)
        }
        .highlightable(id: "general.cli", highlighted: highlighted)
    }

    private func agentRow(_ row: Binding<AgentRow>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.wrappedValue.harness.displayName)
                    Text(row.wrappedValue.harness.configDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if row.wrappedValue.busy {
                    ProgressView().controlSize(.small)
                }
                Toggle("", isOn: Binding(
                    get: { row.wrappedValue.registered },
                    set: { enabled in flip(row, to: enabled) },
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(row.wrappedValue.busy)
            }
            if let error = row.wrappedValue.error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .highlightable(id: "general.agents", highlighted: highlighted)
    }

    /// For every agent that speaks MCP but isn't in the list: the command,
    /// ready to paste.
    private var manualCommandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Anything else that speaks MCP")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: Theme.Space.sm) {
                Text(AgentIntegration.manualCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyButton(text: AgentIntegration.manualCommand)
            }
            .padding(Theme.Space.sm)
            .background(.quaternary.opacity(0.6), in: Theme.innerShape)
        }
    }

    private func flip(_ row: Binding<AgentRow>, to enabled: Bool) {
        row.wrappedValue.busy = true
        row.wrappedValue.error = nil
        let harness = row.wrappedValue.harness
        Task(name: "\(enabled ? "Connect" : "Disconnect") \(harness.displayName)") {
            let failure = enabled
                ? await AgentIntegration.register(harness)
                : await AgentIntegration.unregister(harness)
            row.wrappedValue.error = failure
            row.wrappedValue.registered = AgentIntegration.isRegistered(harness)
            row.wrappedValue.busy = false
        }
    }

    private func refreshAgents() {
        agents = AgentIntegration.detectedHarnesses.map {
            AgentRow(harness: $0, registered: AgentIntegration.isRegistered($0))
        }
    }

    // MARK: - Uninstall

    private var uninstallSection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Uninstall Sevoflurane").font(.headline)
                    Text("Removes what this app installed — the sevo command "
                        + "and its assistant connections included. Your Steam "
                        + "account, and anything you keep, are untouched.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                    .disabled(store.isUninstalling)
            }
            .highlightable(id: "general.uninstall", highlighted: highlighted)
        }
        .confirmationDialog(
            "Uninstall Sevoflurane?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible,
        ) {
            Button("Move App Data to Trash", role: .destructive) {
                uninstall(includingBottle: false)
            }
            Button("Also Move the Bottle and Games", role: .destructive) {
                uninstall(includingBottle: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Steam is stopped first. App data means the engines, the toolkits "
                + "and this app's settings. The bottle holds the Steam client and "
                + "every installed game — \(StorageSettings.size(bottleBytes)) — and everything "
                + "goes to the Trash either way. When it finishes, the app moves "
                + "itself to the Trash and quits.")
        }
    }

    private var bottleBytes: Int64 {
        store.entries
            .filter { ["bottle", "client", "games", "caches"].contains($0.id) }
            .map { max(0, $0.bytes) }
            .reduce(0, +)
    }

    private func uninstall(includingBottle: Bool) {
        Task(name: "Uninstall") {
            await store.uninstall(
                includingBottle: includingBottle, provisioner: provisioner,
                supervisor: supervisor,
            )
            NSApp.terminate(nil)
        }
    }
}

/// A borderless copy button that flips to a checkmark for a moment after
/// copying.
private struct CopyButton: View {
    let text: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            withAnimation(.easeInOut(duration: 0.15)) { copied = true }
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                withAnimation(.easeInOut(duration: 0.3)) { copied = false }
            }
        } label: {
            Image(systemName: copied ? "checkmark" : "doc.on.doc")
                .foregroundStyle(copied ? Color.green : Color.secondary)
        }
        .buttonStyle(.borderless)
        .help("Copy")
    }
}

// MARK: - Graphics

struct GraphicsSettings: View {
    let store: GraphicsStore
    let highlighted: String?
    @State private var showingRendererHelp = false
    @State private var d3dMetalError: String?
    @State private var isAddingD3DMetal = false
    @State private var confirmingD3DMetalRemoval = false
    @State private var showingGPTkDownload = false
    @State private var gptk = GPTkDownload()

    /// Edits go through the store, which decides whether they reach a bottle.
    private var graphics: Binding<BottleGraphics.Selection> {
        Binding(get: { store.selection }, set: { store.update($0) })
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("Game renderer", selection: graphics.renderer) {
                            ForEach(store.availableRenderers, id: \.self) { renderer in
                                Text(renderer.label).tag(renderer)
                            }
                        }
                        Button { showingRendererHelp = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("What each renderer is for")
                        .accessibilityLabel("About the renderers")
                        .popover(isPresented: $showingRendererHelp, arrowEdge: .bottom) {
                            RendererHelp(available: store.availableRenderers)
                        }
                    }
                    Text(store.selection.renderer.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.renderer", highlighted: highlighted)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Report the GPU as", selection: graphics.gpu) {
                        ForEach(GPUIdentity.allCases, id: \.self) { identity in
                            Text(identity.label).tag(identity)
                        }
                    }
                    Text(store.selection.gpu.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.gpu", highlighted: highlighted)
            } footer: {
                Text("Steam's own interface never touches Direct3D — changes "
                    + "take effect the next time a game starts.")
            }
            d3dMetalSection
        }
        .formStyle(.grouped)
    }

    /// Apple's Game Porting Toolkit is not ours to ship, so a managed engine
    /// gets D3DMetal from the user's own download — the arrangement Whisky
    /// uses. Releases and betas install side by side; the newest is used
    /// unless another is chosen here.
    private var d3dMetalSection: some View {
        Section {
            if store.d3dMetalVersions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text(store.engineHasOwnD3DMetal
                        ? "Use a newer D3DMetal"
                        : "Add D3DMetal")
                        .font(.callout.weight(.semibold))
                    Text(store.engineHasOwnD3DMetal
                        ? "CrossOver ships the version it supports. Apple's newer "
                        + "releases can be used instead."
                        : "Direct3D 12 needs Apple's Game Porting Toolkit, which only "
                        + "Apple may distribute.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                D3DMetalVersionPicker(store: store)
            }
            HStack {
                if let d3dMetalError {
                    Text(d3dMetalError).font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                if let removable = removableD3DMetal {
                    Button("Remove \(removable)…", role: .destructive) {
                        confirmingD3DMetalRemoval = true
                    }
                    .disabled(isAddingD3DMetal)
                    .confirmationDialog(
                        "Remove D3DMetal \(removable)?",
                        isPresented: $confirmingD3DMetalRemoval,
                        titleVisibility: .visible,
                    ) {
                        Button("Move to Trash", role: .destructive) {
                            store.removeD3DMetal(version: removable)
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("Games pinned to it fall back to the newest "
                            + "remaining version. It goes to the Trash, so a "
                            + "wrong click is recoverable.")
                    }
                }
                Button("Download from Apple…") { showingGPTkDownload = true }
                    .disabled(isAddingD3DMetal)
                Button(store.d3dMetalVersions.isEmpty
                    ? "Choose Disk Image…" : "Add Another Version…") {
                        addD3DMetal()
                    }
                    .disabled(isAddingD3DMetal)
            }
        } header: {
            Text("Apple's Game Porting Toolkit")
        }
        .sheet(isPresented: $showingGPTkDownload) { gptkDownloadSheet }
    }

    /// The selected version, when it is one of ours to remove — the engine's
    /// own CrossOver copy is not.
    private var removableD3DMetal: String? {
        guard let active = store.activeD3DMetal,
              store.d3dMetalVersions.contains(where: { $0.version == active })
        else { return nil }
        return active
    }

    /// Apple's own download page, in-app: the user signs in and downloads the
    /// release and beta toolkits, which install straight into the engine.
    private var gptkDownloadSheet: some View {
        VStack(spacing: 0) {
            GPTkDownloadPanel(
                download: gptk,
                install: { url in await store.installD3DMetal(from: url) },
            )
            .padding(16)
            Divider()
            HStack {
                Spacer()
                Button("Done") { showingGPTkDownload = false }
                    .keyboardShortcut(.defaultAction)
                    .disabled(gptk.isBusy)
            }
            .padding(16)
        }
        .frame(width: 760, height: 620)
    }

    private func addD3DMetal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit disk image you downloaded."
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isAddingD3DMetal = true
        d3dMetalError = nil
        Task(name: "Install D3DMetal") {
            d3dMetalError = await store.installD3DMetal(from: source)
            isAddingD3DMetal = false
        }
    }
}

/// The installed toolkit versions, plus the engine's own where it has one.
/// An empty tag is that "own" case: a `String?` selection here crashed the
/// compiler's IRGen, and a sentinel costs one line to read.
private struct D3DMetalVersionPicker: View {
    let store: GraphicsStore

    private var selection: Binding<String> {
        Binding(
            get: { store.activeD3DMetal ?? "" },
            set: { store.chooseD3DMetal(version: $0.isEmpty ? nil : $0) },
        )
    }

    var body: some View {
        Picker("D3DMetal version", selection: selection) {
            if store.engineHasOwnD3DMetal {
                Text("CrossOver's own").tag("")
            }
            ForEach(store.d3dMetalVersions, id: \.version) { entry in
                Text(entry.version).tag(entry.version)
            }
        }
    }
}

/// What the five renderers are, in the order someone would try them.
private struct RendererHelp: View {
    let available: [Renderer]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choosing a renderer")
                .font(.headline)
            Text("Each one translates the Windows graphics API a game speaks "
                + "into Metal. A game that stutters or refuses to start is "
                + "usually a game on the wrong one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(available, id: \.self) { renderer in
                VStack(alignment: .leading, spacing: 1) {
                    Text(renderer.label).font(.callout.weight(.semibold))
                    Text(renderer.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Changing this takes effect the next time a game starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
    }
}

// MARK: - Storage

struct StorageSettings: View {
    let store: StorageStore
    let highlighted: String?

    var body: some View {
        Form {
            Section {
                ForEach(store.entries) { entry in
                    if entry.id == "games", !store.games.isEmpty {
                        DisclosureGroup { gameList } label: { row(entry) }
                    } else {
                        row(entry)
                    }
                }
            } header: {
                HStack {
                    Text("On this Mac")
                    Spacer()
                    if store.isMeasuring { ProgressView().controlSize(.small) }
                    Text(Self.size(store.total)).monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("Anything removed here goes to the Trash, so a wrong click "
                    + "costs a drag back rather than a re-download. Uninstalling "
                    + "the app itself lives in General.")
            }
        }
        .formStyle(.grouped)
        .task { await store.measure() }
    }

    /// Sizes as Steam accounts for them, so a row here matches what the
    /// client shows for the same game.
    private var gameList: some View {
        VStack(spacing: 4) {
            ForEach(store.games) { game in
                HStack {
                    Text(game.name).lineLimit(1)
                    Spacer(minLength: Theme.Space.md)
                    Text(Self.size(game.bytes))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
            }
        }
        .padding(.leading, 28)
        .padding(.vertical, 4)
    }

    private func row(_ entry: StorageInventory.Entry) -> some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: entry.icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.name)
                Text(entry.removal?.caution ?? entry.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            // A dash for both "not measured yet" and "nothing there":
            // `ByteCountFormatter` says "Zero KB", which reads like a bug.
            Text(entry.bytes <= 0 ? "—" : Self.size(entry.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if entry.removal != nil {
                Button { store.reclaim(entry) } label: { Image(systemName: "trash") }
                    .buttonStyle(.borderless)
                    .disabled(entry.bytes <= 0)
                    .help("Move \(entry.name.lowercased()) to the Trash")
            }
        }
        .highlightable(id: "storage.\(entry.id)", highlighted: highlighted)
    }

    fileprivate static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

// MARK: - Repair (gallery tile)

/// The gallery's Repair tile — the same `RepairRow` the Engine pane embeds,
/// wrapped in its own Form so it stands alone.
struct RepairSettings: View {
    let provisioner: Provisioner
    let highlighted: String?

    var body: some View {
        Form {
            Section {
                RepairRow(provisioner: provisioner, highlighted: highlighted)
            } footer: {
                Text("Runs the same setup as first launch: anything present is "
                    + "kept, anything missing or broken is reinstalled. Games "
                    + "and saves are untouched.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettings: View {
    let highlighted: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .bold))
            Text("Steam for macOS, natively — version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(
                    "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://kagerou.glass")!,
                )
                Link(
                    "GitHub \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://github.com/kageroumado/sevoflurane")!,
                )
            }
            .font(.system(size: 12))
        }
        .highlightable(id: "about.version", highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
