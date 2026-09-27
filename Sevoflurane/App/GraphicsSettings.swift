import Propofol
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Graphics

/// The one sentence the pane, its notice and the renderer popover all say
/// about a renderer change reaching a game.
private let applyRendererCopy =
    InterfaceCopy.localized("Launch a game from the menu bar to apply changes. Steam restarts if needed.")

struct GraphicsSettings: View {
    let store: GraphicsStore
    let shaders: ShaderStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?
    @State private var d3dMetalError: String?
    @State private var isAddingD3DMetal = false
    @State private var confirmingD3DMetalRemoval = false
    @State private var showingGPTkDownload = false
    @State private var gptk = GPTkDownload()

    /// Edits go through the store, which decides whether they reach a bottle.
    private var graphics: Binding<BottleGraphics.Selection> {
        Binding(get: { store.selection }, set: { store.update($0) })
    }

    /// The renderer the running Steam came up on, while it differs from the
    /// one chosen here.
    private var bootedRenderer: Renderer? {
        guard let booted = BottleGraphics.bootedSelection()?.renderer,
              booted != store.selection.renderer else { return nil }
        return booted
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
                        SettingHelpButton(
                            help: SettingCopy.renderers(store.availableRenderers, footnote: applyRendererCopy),
                        )
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
                if let bootedRenderer {
                    HStack {
                        Text("Steam started on \(bootedRenderer.label). \(applyRendererCopy)")
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
                // The row above says it, with the button, while a change waits.
                if bootedRenderer == nil { Text(applyRendererCopy) }
            }
            rendererVersionsSection
            ShaderPackagesSection(shaders: shaders, highlighted: highlighted)
        }
        .formStyle(.grouped)
        .onAppear {
            store.loadRendererReleases()
            shaders.load()
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
            if BottleGraphics.rendererVersionsChangedSinceBoot() {
                // The renderer picker above says this for a renderer change;
                // a version change is the same restage and was saying
                // nothing at all.
                HStack {
                    Text(applyRendererCopy)
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
            Text("Renderer versions")
        } footer: {
            Text("A change applies the same way. Reset restores the engine's own version.")
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
                    Button("Add from a Disk Image…") { addD3DMetal() }
                    if let removable = removableD3DMetal {
                        Divider()
                        Button("Remove \(removable)…", role: .destructive) {
                            confirmingD3DMetalRemoval = true
                        }
                    }
                } label: {
                    Label("More actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
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
                    Text("D3DMetal uses the newest installed version. Removing the last version disables DirectX 12 in Dormison.")
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
                    ? "CrossOver ships the version it supports. Add a newer one from Apple to replace it."
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
                .font(.callout.weight(.medium))
            Text("In Engine settings, choose an engine that includes D3DMetal. Downloaded toolkits stay installed.")
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
                install: { url in await store.installD3DMetal(from: url, choosing: false) },
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
        panel.message = String(localized: "Choose the Game Porting Toolkit disk image you downloaded.")
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isAddingD3DMetal = true
        d3dMetalError = nil
        Task(name: "Install D3DMetal") {
            d3dMetalError = await store.installD3DMetal(from: source, choosing: true)
            isAddingD3DMetal = false
        }
    }
}

/// The packages the upscaler can run: what is in the store, with its license
/// and removal, and what the catalog can fetch. Its own view, because a
/// download's progress rewrites `shaders.busy` many times a second and only
/// this section reads it.
private struct ShaderPackagesSection: View {
    let shaders: ShaderStore
    let highlighted: SettingsAnchor?
    @State private var removingShaderPackage: ShaderPackages.Package?

    var body: some View {
        let isBusy = shaders.busy != nil
        Section {
            ForEach(shaders.installed) { package in
                InstalledShaderRow(package: package, isBusy: isBusy) {
                    removingShaderPackage = package
                }
            }
            ForEach(shaders.downloadable) { entry in
                DownloadableShaderRow(entry: entry, isBusy: isBusy) {
                    Task(name: "Fetch shader package \(entry.name)") { await shaders.install(entry) }
                }
            }
            if shaders.installed.isEmpty, shaders.downloadable.isEmpty {
                Text(shaders.catalogLoaded
                    ? "No packages installed. The download catalog is unreachable."
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
            Text("Games using this upscaler fall back to Lanczos.")
        }
    }
}

/// A package in the store: its version, license and content, and Remove.
private struct InstalledShaderRow: View {
    let package: ShaderPackages.Package
    let isBusy: Bool
    let remove: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            ShaderPackageSummary(
                title: package.title,
                version: package.manifest.version,
                license: package.manifest.license,
                content: package.manifest.content,
            )
            Spacer(minLength: Theme.Space.sm)
            if let source = package.manifest.source {
                ShaderProjectLink(source: source)
            }
            Button("Remove…", action: remove)
                .disabled(isBusy)
        }
    }
}

/// A package the catalog can fetch, and Download with its size.
private struct DownloadableShaderRow: View {
    let entry: ShaderPackages.Available
    let isBusy: Bool
    let download: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            ShaderPackageSummary(
                title: entry.title, version: entry.version, license: entry.license, content: entry.content,
            )
            Spacer(minLength: Theme.Space.sm)
            if let source = entry.source {
                ShaderProjectLink(source: source)
            }
            Button(entry.size.map { "Download (\(StorageSettings.size($0)))" } ?? "Download", action: download)
                .disabled(isBusy)
        }
    }
}

/// A package's title, version and license, over what it contains.
private struct ShaderPackageSummary: View {
    let title: String
    let version: String
    let license: String
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(title)
                Text("\(version) · \(license)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(InterfaceCopy.localized(content))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The package's project page, opened in the browser.
private struct ShaderProjectLink: View {
    let source: URL

    var body: some View {
        Link(destination: source) {
            Label("Project website", systemImage: "arrow.up.right.square")
                .labelStyle(.iconOnly)
        }
        .help("Project website")
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
                            Text(state.releasesLoaded ? "No newer versions available" : "Looking…")
                        }
                        ForEach(state.downloadable) { release in
                            Button(release.tested ? "\(release.version) · tested" : "\(release.version) · untested") {
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
                    Label("More actions", systemImage: "ellipsis.circle")
                        .labelStyle(.iconOnly)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("More actions")
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
                    Text("The engine's built-in version is used.")
                }
            }
            if let busy = state.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.callout).foregroundStyle(.secondary)
                }
            } else if let newer = state.newer {
                Text(newer.tested
                    ? "\(newer.version) is available and tested with this engine."
                    : "\(newer.version) is available and untested here.")
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
        panel.message = String(localized: "Choose a \(component.label) release archive, or a folder holding its DLLs.")
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let source = panel.url else { return }
        store.addRendererVersion(component, from: source)
    }
}
