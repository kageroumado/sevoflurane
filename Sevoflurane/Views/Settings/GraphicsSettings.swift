import SwiftUI
import UniformTypeIdentifiers

// MARK: - Graphics

/// Settings › Graphics: the renderer and the GPU games are told about, each
/// renderer's versions, the upscaler packages, and every game's picture and
/// mouse defaults.
struct GraphicsSettings: View {
    let store: GraphicsStore
    let shaders: ShaderStore
    /// The active bottle's defaults, whose Picture and Mouse groups this pane
    /// shows; `nil` on an engine that reads none of them.
    var defaults: SettingsStore?
    var steam: SteamActions?
    let highlighted: SettingsAnchor?

    private var graphics: Binding<BottleGraphics.Selection> {
        Binding(get: { store.selection }, set: { store.update($0) })
    }

    var body: some View {
        SettingsForm(highlighted: highlighted) {
            SettingsSection(title: "Renderer", reach: .nextLaunch) {
                SettingsPicker(
                    title: "Renderer",
                    caption: store.selection.renderer.detail,
                    help: SettingCopy.renderers(store.availableRenderers),
                    selection: graphics.renderer,
                ) {
                    ForEach(store.availableRenderers, id: \.self) { renderer in
                        Text(renderer.label).tag(renderer)
                    }
                }
                .highlightable(.graphicsRenderer, highlighted: highlighted)
                SettingsPicker(
                    title: "GPU reported to games", caption: store.selection.gpu.detail, help: .reportedGPU,
                    selection: graphics.gpu,
                ) {
                    ForEach(GPUIdentity.allCases, id: \.self) { identity in
                        Text(identity.label).tag(identity)
                    }
                }
                .highlightable(.graphicsGpu, highlighted: highlighted)
                if let bootedRenderer = store.bootedRenderer {
                    RestartNotice(
                        waiting: String(localized: "Steam is still running on \(bootedRenderer.label)."), steam: steam,
                    )
                }
            }
            SettingsSection(title: "Renderer versions", reach: .nextLaunch) {
                if !store.canHostD3DMetal {
                    DX12HostNotice(macRunsD3DMetal: store.macRunsD3DMetal)
                }
                D3DMetalRow(store: store)
                ForEach(RendererVersions.Component.allCases) { component in
                    RendererVersionRow(store: store, component: component)
                }
                if store.rendererVersionsChangedSinceBoot, store.bootedRenderer == nil {
                    RestartNotice(
                        waiting: String(localized: "Steam is still running on the earlier versions."), steam: steam,
                    )
                }
            }
            ShaderPackagesSection(shaders: shaders, highlighted: highlighted)
            if let defaults {
                SettingSections(
                    store: defaults, shaders: shaders, highlighted: highlighted, groups: [.picture, .mouse],
                )
            }
        }
        .onAppear {
            store.loadRendererReleases()
            shaders.load()
        }
    }
}

/// A change that waits for the next game: what Steam still runs on, and the
/// restart that takes the change now. One restart takes a renderer and a
/// version together, so the card that names the renderer carries the row.
private struct RestartNotice: View {
    let waiting: String
    let steam: SteamActions?

    var body: some View {
        SettingsAction(title: "Pending change", caption: waiting) {
            if let steam {
                Button("Restart Steam") { steam.restartClient() }
            }
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
        if macRunsD3DMetal {
            SettingsJump(
                title: "Update the engine for DirectX 12",
                caption: String(localized: "Your toolkits stay."),
                target: .engineSelection,
            )
        } else {
            SettingsMessage(text: "DirectX 12 needs a Mac with Apple silicon.")
        }
    }
}

/// The D3DMetal row, shaped like the two after it: the picker, then a menu for
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
        SettingsPicker(
            title: "D3DMetal", caption: caption,
            state: .failure(ifPresent: isAddingD3DMetal ? nil : d3dMetalError),
            isWorking: isAddingD3DMetal,
            selection: Binding<String>(
                get: { store.activeD3DMetal ?? "" },
                set: { store.chooseD3DMetal(version: $0.isEmpty ? nil : $0) },
            ),
        ) {
            if store.engineHasOwnD3DMetal {
                Text("CrossOver\u{2019}s own").tag("")
            } else if store.d3dMetalVersions.isEmpty {
                Text("None added").tag("")
            }
            ForEach(store.d3dMetalVersions, id: \.version) { entry in
                Text(entry.version).tag(entry.version)
            }
        } accessory: {
            actionsMenu
        }
        .disabled(isAddingD3DMetal)
        .sheet(isPresented: $showingGPTkDownload) {
            SettingsSheet(isBusy: gptk.isBusy) { showingGPTkDownload = false } content: {
                GPTkDownloadPanel(
                    download: gptk,
                    install: { url, origin in await store.installD3DMetal(from: url, origin: origin, choosing: false) },
                    isSimulated: store.isSimulated,
                )
            }
        }
    }

    /// What the toolkit is doing, or what adding one buys.
    private var caption: String {
        if isAddingD3DMetal { return String(localized: "Installing the toolkit…") }
        guard store.d3dMetalVersions.isEmpty else { return "" }
        return store.engineHasOwnD3DMetal
            ? String(localized: "CrossOver ships the version it supports. Add a newer one from Apple to replace it.")
            : String(localized: "Adds support for DirectX 12 games.")
    }

    /// Apple's download, a disk image, and removal of the chosen version.
    private var actionsMenu: some View {
        SettingsAccessoryMenu {
            Button("Get It from Apple…") { showingGPTkDownload = true }
            Button("Add from a Disk Image…") { addD3DMetal() }
            if let removable = removableD3DMetal {
                Divider()
                Button("Remove \(removable)…", role: .destructive) {
                    confirmingD3DMetalRemoval = true
                }
            }
        }
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
        SettingsSection(
            title: "Upscalers", anchor: .graphicsShaders, help: .upscalerPackages,
            footer: "For games drawn at low resolution: pixel art, anime, visual novels.",
        ) {
            ForEach(shaders.installed) { package in
                ShaderPackageRow(
                    title: package.title, version: package.manifest.version, license: package.manifest.license,
                    description: package.manifest.description, content: package.manifest.content,
                    source: package.manifest.source,
                ) {
                    Button("Remove…") { removingShaderPackage = package }
                        .disabled(isBusy)
                }
            }
            ForEach(shaders.downloadable) { entry in
                ShaderPackageRow(
                    title: entry.title, version: entry.version, license: entry.license,
                    description: entry.description, content: entry.content, source: entry.source,
                ) {
                    Button(entry.size.map { "Download (\(StorageSettings.size($0)))" } ?? "Download") {
                        Task(name: "Fetch shader package \(entry.name)") { await shaders.install(entry) }
                    }
                    .disabled(isBusy)
                }
            }
            if shaders.installed.isEmpty, shaders.downloadable.isEmpty {
                SettingsMessage(
                    text: shaders.catalogLoaded
                        ? "No packages installed. The download catalog is unreachable." : "Looking…",
                )
            }
            ShaderFetchStatus(shaders: shaders)
        }
        .highlightableSection(.graphicsShaders, highlighted: highlighted)
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

/// A package: its title, its version and license, its one button, the
/// project's website, and its description (or its contents when the
/// description is empty).
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
        SettingsAction(title: "\(title)", caption: InterfaceCopy.localized(summary)) {
            SettingsValueText(text: "\(version) · \(license)")
            action
        } accessory: {
            if let source {
                SettingsAccessoryLink(label: "Project website", destination: source)
            }
        }
    }
}

/// One renderer's version picker (the engine's own, then every added version),
/// and its menu: the feed's releases, a release from disk, Reset and removal.
private struct RendererVersionRow: View {
    let store: GraphicsStore
    let component: RendererVersions.Component
    @State private var confirmingRemoval = false

    private var state: GraphicsStore.RendererVersionState {
        store.rendererVersions[component] ?? .init()
    }

    var body: some View {
        SettingsPicker(
            title: "\(component.label)", caption: caption,
            state: .failure(ifPresent: state.busy == nil ? state.error : nil),
            isWorking: state.busy != nil,
            selection: Binding(
                get: { state.chosen ?? "" },
                set: { store.chooseRendererVersion(component, version: $0.isEmpty ? nil : $0) },
            ),
        ) {
            Text(state.defaultVersion.map { "Engine\u{2019}s own (\($0))" } ?? "Engine\u{2019}s own").tag("")
            ForEach(state.installed) { entry in
                Text(entry.version).tag(entry.version)
            }
        } accessory: {
            actionsMenu
        }
        .disabled(state.busy != nil)
    }

    /// What the row is doing, or the release it could move to.
    private var caption: String {
        if let busy = state.busy { return busy }
        guard let newer = state.newer else { return "" }
        return newer.tested
            ? String(localized: "\(newer.version) is available and tested with this engine.")
            : String(localized: "\(newer.version) is available and untested here.")
    }

    private var actionsMenu: some View {
        SettingsAccessoryMenu {
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
                Button("Reset to Engine\u{2019}s Own") {
                    store.chooseRendererVersion(component, version: nil)
                }
                Button("Remove \(chosen)…", role: .destructive) { confirmingRemoval = true }
            }
        }
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
            Text("The engine\u{2019}s built-in version is used.")
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
