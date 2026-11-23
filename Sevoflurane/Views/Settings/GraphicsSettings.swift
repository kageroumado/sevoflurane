import Propofol
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Graphics

/// What the pane, its notice and the renderer popover all say about a renderer
/// change reaching a game.
private let applyRendererCopy =
    InterfaceCopy.localized("Launch a game from the menu bar to apply changes. Steam restarts if needed.")

struct GraphicsSettings: View {
    let store: GraphicsStore
    let shaders: ShaderStore
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    private var graphics: Binding<BottleGraphics.Selection> {
        Binding(get: { store.selection }, set: { store.update($0) })
    }

    var body: some View {
        let bootedRenderer = store.bootedRenderer
        Form {
            Section {
                HelpedRow(
                    caption: store.selection.renderer.detail,
                    help: SettingCopy.renderers(store.availableRenderers, footnote: applyRendererCopy),
                ) {
                    Picker("Game renderer", selection: graphics.renderer) {
                        ForEach(store.availableRenderers, id: \.self) { renderer in
                            Text(renderer.label).tag(renderer)
                        }
                    }
                    .endsOnControlLine()
                }
                .highlightable(.graphicsRenderer, highlighted: highlighted)
                HelpedRow(caption: store.selection.gpu.detail, help: .reportedGPU) {
                    Picker("GPU reported to games", selection: graphics.gpu) {
                        ForEach(GPUIdentity.allCases, id: \.self) { identity in
                            Text(identity.label).tag(identity)
                        }
                    }
                    .endsOnControlLine()
                }
                .highlightable(.graphicsGpu, highlighted: highlighted)
                if let bootedRenderer {
                    ActionRow(title: "Steam started on \(bootedRenderer.label)", caption: applyRendererCopy) {
                        if let steam {
                            Button("Restart Steam") { steam.restartClient() }
                        }
                    }
                }
            } header: {
                Text("Renderer")
            } footer: {
                // While a change waits, the row above says this with its
                // button.
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

    /// Every renderer's versions: Apple's D3DMetal from the user's download,
    /// and the engine's DXMT and DXVK beside any added release.
    private var rendererVersionsSection: some View {
        Section {
            if !store.canHostD3DMetal {
                DX12HostNotice(macRunsD3DMetal: store.macRunsD3DMetal)
            }
            D3DMetalRow(store: store)
            ForEach(RendererVersions.Component.allCases) { component in
                RendererVersionRow(store: store, component: component)
            }
            if store.rendererVersionsChangedSinceBoot {
                // The renderer picker above says this for a renderer change;
                // a version change is the same restage.
                ActionRow(title: "A version changed", caption: applyRendererCopy) {
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
    }
}

/// Shown when no installed engine declares D3DMetal. Apple's toolkit calls
/// pthread from PE code, so it needs a Wine that keeps GS on the thread's own
/// data (CrossOver, and Dormison, whose GS base lives in the thread's TSD), and
/// it runs only on Apple silicon. Added toolkits are kept.
private struct DX12HostNotice: View {
    let macRunsD3DMetal: Bool

    var body: some View {
        SettingsRow(
            caption: macRunsD3DMetal
                ? String(localized: "Choose an engine that includes D3DMetal in Settings › Engine. Your toolkits stay.")
                : "",
        ) {
            (macRunsD3DMetal ? Text("Update the engine for DirectX 12") : Text("DirectX 12 needs a Mac with Apple silicon"))
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// The D3DMetal row, shaped like the two below: the picker, then a menu for
/// Apple's download, a disk image, and removal. An empty tag is CrossOver's
/// own copy or the placeholder. Never make the selection `String?`: that
/// crashes the compiler's IRGen.
private struct D3DMetalRow: View {
    let store: GraphicsStore
    @State private var d3dMetalError: String?
    @State private var isAddingD3DMetal = false
    @State private var confirmingD3DMetalRemoval = false
    @State private var showingGPTkDownload = false
    @State private var gptk = GPTkDownload()

    var body: some View {
        let selection = Binding<String>(
            get: { store.activeD3DMetal ?? "" },
            set: { store.chooseD3DMetal(version: $0.isEmpty ? nil : $0) },
        )
        SettingsRow(caption: caption, isWarning: d3dMetalError != nil && !isAddingD3DMetal) {
            if isAddingD3DMetal {
                ProgressView().controlSize(.small)
            }
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
            .endsOnControlLine()
            .disabled(isAddingD3DMetal || (store.d3dMetalVersions.isEmpty && !store.engineHasOwnD3DMetal))
        } accessory: {
            actionsMenu
        }
        .sheet(isPresented: $showingGPTkDownload) { gptkDownloadSheet }
    }

    /// What the toolkit is doing, what went wrong, or what adding one buys.
    private var caption: String {
        if isAddingD3DMetal { return String(localized: "Installing the toolkit…") }
        if let d3dMetalError { return d3dMetalError }
        guard store.d3dMetalVersions.isEmpty else { return "" }
        return store.engineHasOwnD3DMetal
            ? String(localized: "CrossOver ships the version it supports. Add a newer one from Apple to replace it.")
            : String(localized: "Adds support for DirectX 12 games.")
    }

    /// Apple's download, a disk image, and removal of the chosen version.
    private var actionsMenu: some View {
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
        .menuIndicator(.hidden)
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

    /// The selected version, when it is a user-added one that can be removed.
    private var removableD3DMetal: String? {
        guard let active = store.activeD3DMetal,
              store.d3dMetalVersions.contains(where: { $0.version == active })
        else { return nil }
        return active
    }

    /// Apple's download page, in-app: the user signs in, and the toolkits
    /// install straight into the engine.
    private var gptkDownloadSheet: some View {
        VStack(spacing: 0) {
            GPTkDownloadPanel(
                download: gptk,
                install: { url, origin in await store.installD3DMetal(from: url, origin: origin, choosing: false) },
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
        .frame(width: 760, height: 820)
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

/// The upscaler packages, installed and fetchable. Its own view because a
/// download rewrites `shaders.busy` many times a second and only this section
/// reads it.
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
            HStack(spacing: 6) {
                Text("Upscalers")
                SettingHelpButton(help: .upscalerPackages)
            }
        } footer: {
            Text("For games drawn at low resolution: pixel art, anime, visual novels.")
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

private struct InstalledShaderRow: View {
    let package: ShaderPackages.Package
    let isBusy: Bool
    let remove: () -> Void

    var body: some View {
        ShaderPackageRow(
            title: package.title,
            version: package.manifest.version,
            license: package.manifest.license,
            description: package.manifest.description,
            content: package.manifest.content,
            source: package.manifest.source,
        ) {
            Button("Remove…", action: remove)
                .disabled(isBusy)
        }
    }
}

private struct DownloadableShaderRow: View {
    let entry: ShaderPackages.Available
    let isBusy: Bool
    let download: () -> Void

    var body: some View {
        ShaderPackageRow(
            title: entry.title, version: entry.version, license: entry.license,
            description: entry.description, content: entry.content, source: entry.source,
        ) {
            Button(entry.size.map { "Download (\(StorageSettings.size($0)))" } ?? "Download", action: download)
                .disabled(isBusy)
        }
    }
}

/// A package: its title, version and license, its one button, the project's
/// website, and its description (or its contents when the description is empty).
private struct ShaderPackageRow<Action: View>: View {
    let title: String
    let version: String
    let license: String
    let description: String
    let content: String
    let source: URL?
    @ViewBuilder var action: Action

    private var summary: String {
        description.trimmingCharacters(in: .whitespaces).isEmpty ? content : description
    }

    var body: some View {
        SettingsRow(caption: InterfaceCopy.localized(summary)) {
            LabeledContent {
                action
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    Text(title)
                    Text("\(version) · \(license)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        } accessory: {
            if let source { ShaderProjectLink(source: source) }
        }
    }
}

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

/// One renderer's version picker (the engine's own, then every added version),
/// its fetch menu, and Reset.
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
        SettingsRow(caption: caption, isWarning: state.error != nil && state.busy == nil) {
            if state.busy != nil {
                ProgressView().controlSize(.small)
            }
            Picker(component.label, selection: selection) {
                Text(state.defaultVersion.map { "Engine's own (\($0))" } ?? "Engine's own").tag("")
                ForEach(state.installed) { entry in
                    Text(entry.version).tag(entry.version)
                }
            }
            .endsOnControlLine()
            .disabled(state.busy != nil)
        } accessory: {
            actionsMenu
        }
    }

    /// What the row is doing, what went wrong, or the release it could move to.
    private var caption: String {
        if let busy = state.busy { return busy }
        if let error = state.error { return error }
        guard let newer = state.newer else { return "" }
        return newer.tested
            ? String(localized: "\(newer.version) is available and tested with this engine.")
            : String(localized: "\(newer.version) is available and untested here.")
    }

    /// The feed's releases, a release from disk, Reset and removal.
    private var actionsMenu: some View {
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
        .menuIndicator(.hidden)
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
