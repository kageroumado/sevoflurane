import Propofol
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

// MARK: - General

struct GeneralSettings: View {
    let provisioner: Provisioner
    let store: StorageStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
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
        var id: String {
            harness.id
        }
    }

    var body: some View {
        Form {
            Section {
                Toggle("Open at login", isOn: $openAtLogin)
                .toggleStyle(.switch)
                .onChange(of: openAtLogin) { _, enabled in
                    provisioner.setOpenAtLogin(enabled)
                }
                .highlightable(.generalOpenAtLogin, highlighted: highlighted)
                if let steam {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Steam settings")
                            Text("Downloads, controllers, and the Steam interface.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Open…") { steam.openSteamSettings() }
                    }
                    .highlightable(.generalSteamSettings, highlighted: highlighted)
                }
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
                    Text("Allow each assistant to control Steam through MCP.")
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
                    ? "Installed at /usr/local/bin/sevo."
                    : "Adds sevo for Terminal and MCP. Requires an administrator password.")
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
        .highlightable(.generalCli, highlighted: highlighted)
    }

    private func agentRow(_ row: Binding<AgentRow>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: Theme.Space.md) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.wrappedValue.harness.displayName)
                        .help(row.wrappedValue.harness.configDescription)
                }
                Spacer()
                if row.wrappedValue.busy {
                    ProgressView().controlSize(.small)
                }
                Toggle(row.wrappedValue.harness.displayName, isOn: Binding(
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
        .highlightable(.generalAgents, highlighted: highlighted)
    }

    /// For every agent that speaks MCP but isn't in the list: the command,
    /// ready to paste.
    private var manualCommandRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Other MCP assistants")
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
                    Text("Remove Sevoflurane and its downloaded engines and toolkits. You can choose to keep games.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Button("Uninstall…", role: .destructive) { confirmingUninstall = true }
                    .disabled(store.isUninstalling)
            }
            .highlightable(.generalUninstall, highlighted: highlighted)
        }
        .confirmationDialog(
            "Uninstall Sevoflurane?",
            isPresented: $confirmingUninstall,
            titleVisibility: .visible,
        ) {
            Button("Uninstall, Keep Games", role: .destructive) {
                uninstall(includingBottle: false)
            }
            Button("Uninstall Everything", role: .destructive) {
                uninstall(includingBottle: true)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Steam will close. Sevoflurane removes its downloaded engines and toolkits, resets preferences, and disconnects assistants.\n\nKeep Games leaves Steam and its \(StorageSettings.size(bottleBytes)) of files in place. Uninstall Everything moves those files to the Trash too, including local saves stored in the bottle.\n\nThe app moves itself to the Trash and quits. Your Steam account and cloud saves are kept.")
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
    let shaders: ShaderStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var showingRendererHelp = false
    @State private var removingShaderPackage: ShaderPackages.Package?
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
                .highlightable(.graphicsRenderer, highlighted: highlighted)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("GPU reported to games", selection: graphics.gpu) {
                        ForEach(GPUIdentity.allCases, id: \.self) { identity in
                            Text(identity.label).tag(identity)
                        }
                    }
                    Text(store.selection.gpu.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(.graphicsGpu, highlighted: highlighted)
                if let booted = BottleGraphics.bootedSelection()?.renderer,
                   booted != store.selection.renderer {
                    HStack {
                        Text("Launch from the menu bar to apply \(store.selection.renderer.label), or restart Steam.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        if let steam {
                            Button("Restart Steam") { steam.restartClient() }
                        }
                    }
                }
            } header: {
                Text("Renderer")
            } footer: {
                Text("Launch games from the menu bar to apply renderer changes. Steam restarts if needed.")
            }
            rendererVersionsSection
            shaderPackagesSection
        }
        .formStyle(.grouped)
        .onAppear {
            store.loadRendererReleases()
            shaders.load()
        }
    }

    /// The packages the upscaler can run: what is in the store, with its
    /// license and removal, and what the catalog can fetch.
    private var shaderPackagesSection: some View {
        Section {
            ForEach(shaders.installed) { package in
                installedShaderRow(package)
            }
            ForEach(shaders.downloadable) { entry in
                downloadableShaderRow(entry)
            }
            if shaders.installed.isEmpty, shaders.downloadable.isEmpty {
                Text(shaders.catalogLoaded
                    ? "No packages installed. The download catalog is unavailable."
                    : "Looking…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            ShaderFetchStatus(shaders: shaders)
        } header: {
            Text("Shader packages")
        } footer: {
            Text("Choose an upscaler in Engine or Games.")
        }
        .highlightable(.graphicsShaders, highlighted: highlighted)
        .confirmationDialog(
            "Remove \(removingShaderPackage?.title ?? "")?",
            isPresented: Binding(
                get: { removingShaderPackage != nil },
                set: { if !$0 { removingShaderPackage = nil } },
            ),
            titleVisibility: .visible,
            presenting: removingShaderPackage,
        ) { package in
            Button("Move to Trash", role: .destructive) { shaders.remove(package) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Games using this package will use Lanczos until it is reinstalled.")
        }
    }

    private func installedShaderRow(_ package: ShaderPackages.Package) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(package.title)
                    Text("\(package.manifest.version) · \(package.manifest.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(package.manifest.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            if let source = package.manifest.source {
                Link(destination: source) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Project website")
            }
            Button("Remove…") { removingShaderPackage = package }
                .disabled(shaders.busy != nil)
        }
    }

    private func downloadableShaderRow(_ entry: ShaderPackages.Available) -> some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(entry.title)
                    Text("\(entry.version) · \(entry.license)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(entry.content)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: Theme.Space.sm)
            if let source = entry.source {
                Link(destination: source) {
                    Image(systemName: "arrow.up.right.square")
                }
                .help("Project website")
            }
            Button(entry.size.map { "Download (\(StorageSettings.size($0)))" } ?? "Download") {
                Task(name: "Fetch shader package \(entry.name)") { await shaders.install(entry) }
            }
            .disabled(shaders.busy != nil)
        }
    }

    /// Every renderer's versions in one place: Apple's D3DMetal from the
    /// user's own download, and the DXMT and DXVK the engine shipped beside
    /// any release added later. The engine's own is one click away again.
    private var rendererVersionsSection: some View {
        Section {
            if !store.engineHasOwnD3DMetal, !store.availableRenderers.contains(.d3dmetal) {
                dx12HostNotice
            }
            d3dMetalRow
            ForEach(RendererVersions.Component.allCases) { component in
                RendererVersionRow(store: store, component: component)
            }
        } header: {
            Text("Renderer versions")
        } footer: {
            Text("DXMT and DXVK version changes apply after Steam restarts. Reset restores the engine's bundled version.")
        }
        .sheet(isPresented: $showingGPTkDownload) { gptkDownloadSheet }
    }

    /// The D3DMetal row in the same shape as the two below it: the picker,
    /// then a menu for Apple's download, a disk image on hand, and removal.
    /// An empty tag is CrossOver's own copy or, with nothing added, the
    /// placeholder: a `String?` selection here crashed the compiler's IRGen.
    private var d3dMetalRow: some View {
        let selection = Binding<String>(
            get: { store.activeD3DMetal ?? "" },
            set: { store.chooseD3DMetal(version: $0.isEmpty ? nil : $0) },
        )
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("D3DMetal", selection: selection) {
                    if store.engineHasOwnD3DMetal {
                        Text("CrossOver's own").tag("")
                    } else if store.d3dMetalVersions.isEmpty {
                        Text("None added").tag("")
                    }
                    ForEach(store.d3dMetalVersions, id: \.version) { entry in
                        Text(entry.version).tag(entry.version)
                    }
                }
                .disabled(isAddingD3DMetal || (store.d3dMetalVersions.isEmpty && !store.engineHasOwnD3DMetal))
                Menu {
                    Button("Get It from Apple…") { showingGPTkDownload = true }
                    Button("Add from a Downloaded Disk Image…") { addD3DMetal() }
                    if let removable = removableD3DMetal {
                        Divider()
                        Button("Remove \(removable)…", role: .destructive) {
                            confirmingD3DMetalRemoval = true
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(isAddingD3DMetal)
                .confirmationDialog(
                    "Remove D3DMetal \(removableD3DMetal ?? "")?",
                    isPresented: $confirmingD3DMetalRemoval,
                    titleVisibility: .visible,
                ) {
                    Button("Move to Trash", role: .destructive) {
                        if let removable = removableD3DMetal {
                            store.removeD3DMetal(version: removable)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("D3DMetal will use the newest remaining version. Removing the last copy from Dormison disables DirectX 12 support.")
                }
            }
            if isAddingD3DMetal {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Installing the toolkit…")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } else if store.d3dMetalVersions.isEmpty {
                Text(store.engineHasOwnD3DMetal
                    ? "CrossOver includes the version it supports; a newer one from Apple can replace it here."
                    : "Adds support for DirectX 12 games.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let d3dMetalError {
                Label(d3dMetalError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Shown when no installed engine declares D3DMetal. Apple's toolkit
    /// calls pthread from PE code, so it needs a Wine that keeps GS on the
    /// thread's own data while PE code runs: CrossOver's does, and Dormison
    /// does (its GS base lives on the thread's TSD). Toolkits added meanwhile
    /// are kept for the engine that gains them.
    private var dx12HostNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Update the engine for DirectX 12")
                .font(.callout.weight(.semibold))
            Text("Choose an engine with D3DMetal support in Engine. Downloaded toolkits stay installed when you switch.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
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
                isSimulated: store.isSimulated,
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

/// One renderer: the version picker (the engine's own, then every added
/// version), the fetch and folder menu, and Reset. Mirrors the D3DMetal
/// picker above it.
private struct RendererVersionRow: View {
    let store: GraphicsStore
    let component: RendererVersions.Component
    @State private var confirmingRemoval = false

    private var state: GraphicsStore.RendererVersionState {
        store.rendererVersions[component] ?? .init()
    }

    private var selection: Binding<String> {
        Binding(
            get: { state.chosen ?? "" },
            set: { store.chooseRendererVersion(component, version: $0.isEmpty ? nil : $0) },
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker(component.label, selection: selection) {
                    Text(state.defaultVersion.map { "Engine's own (\($0))" } ?? "Engine's own").tag("")
                    ForEach(state.installed) { entry in
                        Text(entry.version).tag(entry.version)
                    }
                }
                .disabled(state.busy != nil)
                Menu {
                    Section("Download") {
                        if state.downloadable.isEmpty {
                            Text(state.releasesLoaded ? "Nothing newer to fetch" : "Looking…")
                        }
                        ForEach(state.downloadable) { release in
                            Button(release.tested ? "\(release.version) — tested" : "\(release.version) — untested") {
                                store.downloadRendererVersion(release)
                            }
                        }
                    }
                    Button("Add from Folder or Archive…") { addFromDisk() }
                    if let chosen = state.chosen {
                        Divider()
                        Button("Reset to Engine's Own") {
                            store.chooseRendererVersion(component, version: nil)
                        }
                        Button("Remove \(chosen)…", role: .destructive) { confirmingRemoval = true }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .disabled(state.busy != nil)
                .confirmationDialog(
                    "Remove \(component.label) \(state.chosen ?? "")?",
                    isPresented: $confirmingRemoval, titleVisibility: .visible,
                ) {
                    Button("Move to Trash", role: .destructive) {
                        if let chosen = state.chosen {
                            store.removeRendererVersion(component, version: chosen)
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("The engine's bundled version will be used.")
                }
            }
            if let busy = state.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
            } else if let newer = state.newer {
                Text("\(newer.version) is available" + (newer.tested ? ", tested with this engine." : ", untested here."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            if let error = state.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func addFromDisk() {
        let panel = NSOpenPanel()
        panel.message = "Choose a \(component.label) release archive, or a folder holding its DLLs."
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        store.addRendererVersion(component, from: source)
    }
}

/// What the five renderers are, in the order someone would try them.
private struct RendererHelp: View {
    let available: [Renderer]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choosing a renderer")
                .font(.headline)
            Text("These renderers translate Direct3D graphics for macOS. Try another if a game has graphics problems.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(available, id: \.self) { renderer in
                VStack(alignment: .leading, spacing: 1) {
                    Text(renderer.label).font(.callout.weight(.semibold))
                    Text(renderer.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Launch from the menu bar to apply changes. Steam restarts if needed.")
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
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    var body: some View {
        Form {
            Section {
                ForEach(store.entries) { entry in
                    if entry.id == StorageInventory.Entry.gamesID, !store.games.isEmpty {
                        DisclosureGroup { gameList } label: { row(entry) }
                    } else {
                        row(entry)
                    }
                }
                if store.needsClientRestart, let steam {
                    HStack {
                        Text("Steam sees linked and unlinked games after a restart.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Restart Steam") {
                            store.applyPendingLinks()
                            steam.restartClient()
                            store.acknowledgeRestart()
                        }
                    }
                }
                if let error = store.linkError {
                    Text(error).font(.callout).foregroundStyle(.orange)
                }
            } header: {
                HStack {
                    Text("On this Mac")
                    Spacer()
                    if store.isMeasuring { ProgressView().controlSize(.small) }
                    Text(Self.size(store.total)).monospacedDigit().foregroundStyle(.secondary)
                }
            } footer: {
                Text("Caches and downloaded components go to the Trash. Games are uninstalled through Steam.")
            }
            sharingSection
        }
        .formStyle(.grouped)
        .task { await store.measure() }
    }

    /// Sizes as Steam accounts for them, so a row here matches what the
    /// client shows for the same game.
    private var gameList: some View {
        VStack(spacing: 4) {
            ForEach(store.games) { game in
                gameRow(game)
            }
        }
        .padding(.leading, 28)
        .padding(.vertical, 4)
    }

    private func gameRow(_ game: StorageInventory.Game) -> some View {
        let linked = store.linkedGames.contains(game.id)
        return HStack {
            Text(game.name).lineLimit(1)
            if linked {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("Shared from another bottle — one copy on disk")
            }
            Spacer(minLength: Theme.Space.md)
            Text(Self.size(game.bytes))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            if steam != nil || linked {
                Button {
                    if linked {
                        store.unlink(game)
                    } else {
                        steam?.uninstall(game.id)
                    }
                } label: {
                    Image(systemName: linked ? "link.badge.minus" : "trash")
                }
                .buttonStyle(.borderless)
                .help(linked
                    ? "Remove the link — the files stay in their own bottle"
                    : "Uninstall through Steam (it asks first)")
            }
        }
        .font(.callout)
    }

    /// Games installed in other bottles, one Link away from playable here.
    @ViewBuilder private var sharingSection: some View {
        if !store.linkable.isEmpty || !store.pendingLinks.isEmpty {
            Section {
                ForEach(store.pendingLinks) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name).lineLimit(1)
                            Text("linked — appears when Steam restarts")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.md)
                        Image(systemName: "link")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Button {
                            store.cancelPendingLink(candidate)
                        } label: {
                            Image(systemName: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .help("Undo the link")
                    }
                    .font(.callout)
                }
                ForEach(store.linkable) { candidate in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(candidate.name).lineLimit(1)
                            Text("in \u{201C}\(candidate.sourceBottle)\u{201D} — \(candidate.sourceEngine)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: Theme.Space.md)
                        Text(Self.size(candidate.bytes))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Button("Link") { store.link(candidate) }
                    }
                    .font(.callout)
                }
            } header: {
                Text("In your other bottles")
            } footer: {
                Text("Linking shares a game's files from another bottle — one "
                    + "copy on disk, no second download. Steam verifies them on "
                    + "first launch; save files stay per-bottle.")
            }
            .highlightable(.storageSharing, highlighted: highlighted)
        }
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
        // Games is the one row search can reach; the rest are read, not
        // navigated to.
        .highlightable(
            entry.id == StorageInventory.Entry.gamesID ? .storageGames : nil,
            highlighted: highlighted,
        )
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
    let highlighted: SettingsAnchor?

    var body: some View {
        Form {
            Section {
                RepairRow(provisioner: provisioner, highlighted: highlighted)
            } footer: {
                Text("Repair checks the engine, bottle, and Steam installation, keeping your games and saves.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

struct AboutSettings: View {
    let highlighted: SettingsAnchor?
    @State private var savingDiagnostics = false
    @State private var diagnosticsError: String?

    /// The bundled CLI writes the zip (`sevo diag`), so the app and the
    /// terminal produce the same report; Finder then shows it.
    private func saveDiagnostics() {
        savingDiagnostics = true
        diagnosticsError = nil
        Task(name: "Save diagnostics") {
            let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sevo")
            let result = await Subprocess.run(
                helper.path, ["diag", "--steam-logs"], capture: .combined, timeout: .seconds(90),
            )
            savingDiagnostics = false
            let path = result.output.split(separator: "\n").last.map(String.init) ?? ""
            guard result.status == 0, path.hasSuffix(".zip") else {
                diagnosticsError = "Could not write the report: \(result.output.suffix(200))"
                return
            }
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .bold))
            Text("Version \(Self.version)")
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
            HStack(spacing: 10) {
                Button("Acknowledgments") {
                    NSApp.sendAction(#selector(AppDelegate.showAcknowledgements(_:)), to: nil, from: nil)
                }
                Button("License") {
                    NSApp.sendAction(#selector(AppDelegate.showLicense(_:)), to: nil, from: nil)
                }
                Button(savingDiagnostics ? "Saving…" : "Save Diagnostics…") { saveDiagnostics() }
                    .disabled(savingDiagnostics)
                    .highlightable(.aboutDiagnostics, highlighted: highlighted)
            }
            .controlSize(.small)
            .padding(.top, 6)
            Text("Saves logs, system details, and recent crash reports to a ZIP on your Desktop. Review it before sharing.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            if let diagnosticsError {
                Text(diagnosticsError).font(.caption).foregroundStyle(.red)
            }
        }
        .highlightable(.aboutVersion, highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
