import Foundation

/// Where the Graphics pane reads and writes.
///
/// Everything that reaches an engine or a bottle goes through
/// ``GraphicsEnvironment`` rather than ``BottleGraphics`` directly: the gallery
/// draws every surface, and a pane wired straight to the bottle would let a
/// stray click rewrite the machine's real bottle. A simulated environment
/// keeps the same shape in memory and touches nothing.
@MainActor
@Observable
final class GraphicsStore {
    private(set) var selection: BottleGraphics.Selection
    private(set) var d3dMetalVersions: [D3DMetalInstaller.Installed]
    private(set) var activeD3DMetal: String?
    private let environment: any GraphicsEnvironment

    init(environment: (any GraphicsEnvironment)? = nil) {
        let environment = environment ?? LiveGraphicsEnvironment()
        self.environment = environment
        selection = environment.currentSelection()
        d3dMetalVersions = environment.installedToolkits()
        activeD3DMetal = environment.activeToolkit()?.version
        for component in RendererVersions.Component.allCases {
            rendererVersions[component] = RendererVersionState(
                installed: environment.installedRendererVersions(component),
                chosen: environment.chosenRendererVersion(component),
                defaultVersion: environment.defaultRendererVersion(component),
            )
        }
    }

    // MARK: - Renderer versions

    /// One component's versions as the pane shows them: what is on disk, what
    /// is chosen, what the engine shipped, and what can be fetched.
    struct RendererVersionState: Equatable {
        var installed: [RendererVersions.Installed] = []
        var chosen: String?
        var defaultVersion: String?
        var releases: [RendererVersions.Release] = []
        var releasesLoaded = false
        /// What is happening to it right now, for a progress line.
        var busy: String?
        var error: String?

        /// A release newer than everything on disk and than the default.
        var newer: RendererVersions.Release? {
            RendererVersions.newerRelease(
                than: installed.map(\.version), default: defaultVersion, among: releases,
            )
        }

        /// The releases not yet on disk and not the default, for the download menu.
        var downloadable: [RendererVersions.Release] {
            let have = Set(installed.map(\.version) + [defaultVersion].compactMap(\.self))
            return releases.filter { !have.contains($0.version) }
        }
    }

    private(set) var rendererVersions: [RendererVersions.Component: RendererVersionState] = [:]

    /// Asks each project's releases once per store, the first time the pane
    /// wants them.
    func loadRendererReleases() {
        for component in RendererVersions.Component.allCases
            where rendererVersions[component]?.releasesLoaded == false {
            rendererVersions[component]?.releasesLoaded = true
            Task(name: "List \(component.label) releases") { [weak self] in
                guard let self else { return }
                let releases = await environment.rendererReleases(component)
                rendererVersions[component]?.releases = releases
            }
        }
    }

    /// `nil` chooses the engine's own — the reset.
    func chooseRendererVersion(_ component: RendererVersions.Component, version: String?) {
        rendererVersions[component]?.chosen = version
        environment.chooseRendererVersion(component, version: version)
        EventLog.shared.log(.setup, "\(component.label): \(version ?? "the engine's own") from the next boot")
    }

    func downloadRendererVersion(_ release: RendererVersions.Release) {
        installRendererVersion(
            release.component, from: release.url, version: release.version, sha256: release.sha256,
            describedAs: "Downloading \(release.component.label) \(release.version)…",
        )
    }

    func addRendererVersion(_ component: RendererVersions.Component, from source: URL) {
        installRendererVersion(
            component, from: source, version: nil, sha256: nil,
            describedAs: "Adding \(source.lastPathComponent)…",
        )
    }

    private func installRendererVersion(
        _ component: RendererVersions.Component, from source: URL, version: String?, sha256: String?,
        describedAs phase: String,
    ) {
        guard rendererVersions[component]?.busy == nil else { return }
        rendererVersions[component]?.busy = phase
        rendererVersions[component]?.error = nil
        Task(name: "Install \(component.label)") { [weak self] in
            guard let self else { return }
            do {
                let entry = try await environment.installRendererVersion(
                    component, from: source, version: version, sha256: sha256,
                )
                rendererVersions[component]?.installed = environment.installedRendererVersions(component)
                chooseRendererVersion(component, version: entry.version)
                EventLog.shared.log(.setup, "\(component.label) \(entry.version) added")
            } catch {
                rendererVersions[component]?.error = "\(error)"
            }
            rendererVersions[component]?.busy = nil
        }
    }

    func removeRendererVersion(_ component: RendererVersions.Component, version: String) {
        guard let entry = rendererVersions[component]?.installed.first(where: { $0.version == version })
        else { return }
        do {
            try environment.removeRendererVersion(entry)
        } catch {
            rendererVersions[component]?.error = "\(error)"
            return
        }
        rendererVersions[component]?.installed = environment.installedRendererVersions(component)
        if rendererVersions[component]?.chosen == version {
            chooseRendererVersion(component, version: nil)
        }
        EventLog.shared.log(.setup, "\(component.label) \(version) moved to the Trash")
    }

    /// Where installed toolkits are kept for this engine.
    var toolkitStore: URL {
        environment.toolkitStore
    }

    /// Whether this store's effects are simulated. The pane reads it to stand
    /// Apple's real download page down.
    var isSimulated: Bool {
        environment.isSimulation
    }

    /// Whether the engine brings a D3DMetal of its own, which the user's copy
    /// then replaces rather than supplies.
    var engineHasOwnD3DMetal: Bool {
        environment.engineHasOwnD3DMetal
    }

    /// The renderers the machine can switch between. CrossOver carries
    /// everything; managed engines pool what each declares in its
    /// `engine-info.json`, and choosing a renderer boots an installed engine
    /// that hosts it (D3DMetal needs the `__wine_unix_call` export that only
    /// Sevoflurane's own engine carries).
    var availableRenderers: [Renderer] {
        guard !engineHasOwnD3DMetal else { return Renderer.allCases }
        return Renderer.allCases.filter(Set(environment.hostedRenderers()).contains)
    }

    func update(_ selection: BottleGraphics.Selection) {
        guard selection != self.selection else { return }
        self.selection = selection
        do {
            try environment.apply(selection)
            EventLog.shared.log(
                .setup,
                "graphics: renderer=\(selection.renderer.rawValue) "
                    + "msync=\(selection.msync) gpu=\(selection.gpu.rawValue)",
            )
        } catch {
            EventLog.shared.log(.setup, "graphics change failed: \(error)")
        }
    }

    /// `nil` means the engine's own — CrossOver's copy, with no shadow tree.
    func chooseD3DMetal(version: String?) {
        activeD3DMetal = version
        do {
            try environment.chooseToolkit(version: version)
        } catch {
            EventLog.shared.log(.setup, "D3DMetal version change failed: \(error)")
        }
    }

    /// Trashes an installed toolkit version. The newest remaining one (or
    /// the engine's own copy, where the engine has one) takes over when the
    /// removed version was active.
    func removeD3DMetal(version: String) {
        guard let entry = d3dMetalVersions.first(where: { $0.version == version })
        else { return }
        do {
            try environment.removeToolkit(entry)
        } catch {
            EventLog.shared.log(.setup, "D3DMetal \(version) removal failed: \(error)")
            return
        }
        d3dMetalVersions = environment.installedToolkits()
        EventLog.shared.log(.setup, "D3DMetal \(version) moved to the Trash")
        if activeD3DMetal == version {
            chooseD3DMetal(version: d3dMetalVersions.last?.version)
        }
    }

    /// Answers the failure, so the pane can show it.
    func installD3DMetal(from source: URL) async -> String? {
        do {
            let entry = try await environment.installToolkit(from: source)
            d3dMetalVersions = environment.installedToolkits()
            activeD3DMetal = entry.version
            EventLog.shared.log(.setup, "D3DMetal \(entry.version) added to the engine")
            return nil
        } catch {
            return "\(error)"
        }
    }
}
