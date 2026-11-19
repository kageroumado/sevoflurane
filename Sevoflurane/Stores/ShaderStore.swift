import Foundation

/// Where the upscaler pickers and Settings › Graphics › Upscalers read
/// and write.
///
/// What is in the store is read at init and after every change; the catalog
/// is fetched once per store, the first time a picker wants it, after the
/// bundle's own packages have been copied in. A simulated store keeps a
/// fixture in memory for the gallery and the demo build, so drawing the
/// panes fetches nothing and trashes nothing.
@MainActor
@Observable
final class ShaderStore {
    private(set) var installed: [ShaderPackages.Package] = []
    private(set) var catalog: [ShaderPackages.Available] = []
    private(set) var catalogLoaded = false
    /// The package being fetched, and how far along.
    private(set) var busy: Busy?
    private(set) var error: String?

    struct Busy: Equatable {
        let name: String
        let title: String
        /// `nil` until the size is known.
        var fraction: Double?
    }

    let isSimulated: Bool

    init(simulated: Bool = false) {
        isSimulated = simulated
        if simulated {
            installed = [Self.demoPackage]
            catalog = ShaderPackages.builtInCatalog
            catalogLoaded = true
        } else {
            installed = ShaderPackages.installed()
        }
    }

    /// What the upscaler picker offers, in order.
    var choices: [ShaderPackages.Choice] {
        ShaderPackages.choices(installed: installed, catalog: catalog)
    }

    /// The catalog's packages that are not in the store.
    var downloadable: [ShaderPackages.Available] {
        let have = Set(installed.map(\.name))
        return catalog.filter { !have.contains($0.name) }
    }

    /// Copies the bundle's packages in and asks the manifest for the rest,
    /// once per store.
    func load() {
        guard !catalogLoaded else { return }
        catalogLoaded = true
        Task(name: "List shader packages") { [weak self] in
            let listed = await Task.detached(name: "Read the shader store") {
                ShaderPackages.ensureBundled()
                let manifest = try? await EngineManifest.fetch()
                return (installed: ShaderPackages.installed(), catalog: ShaderPackages.catalog(manifest: manifest))
            }.value
            guard let self else { return }
            installed = listed.installed
            catalog = listed.catalog
        }
    }

    /// Puts a package in the store and answers it, or `nil` after a failure,
    /// which `error` then carries. One fetch at a time.
    func install(_ entry: ShaderPackages.Available) async -> ShaderPackages.Package? {
        guard busy == nil else { return nil }
        busy = Busy(name: entry.name, title: entry.title, fraction: nil)
        error = nil
        defer { busy = nil }
        if isSimulated {
            return await installSimulated(entry)
        }
        do {
            let package = try await ShaderPackages.install(entry) { fraction in
                DispatchQueue.main.async { self.busy?.fraction = fraction }
            }
            installed = ShaderPackages.installed()
            EventLog.shared.log(.setup, "shader package \(package.title) \(package.manifest.version) installed")
            return package
        } catch {
            self.error = "\(error)"
            return nil
        }
    }

    /// Moves a package to the Trash. A setting naming it is left as it is:
    /// the driver falls back to Lanczos and says so, and putting the package
    /// back makes the setting good again.
    func remove(_ package: ShaderPackages.Package) {
        error = nil
        if isSimulated {
            installed.removeAll { $0.name == package.name }
            EventLog.shared.log(.setup, "demo: shaders: would move \(package.title) to the Trash")
            return
        }
        do {
            try ShaderPackages.remove(package)
        } catch {
            self.error = "\(error)"
            return
        }
        installed = ShaderPackages.installed()
        EventLog.shared.log(.setup, "shader package \(package.title) moved to the Trash")
    }

    // MARK: - Fixtures

    private static let demoPackage = ShaderPackages.Package(
        manifest: .init(
            name: "anime4k-c", title: "Anime4K",
            description: "Anime4K mode C. Removes noise while it upscales.",
            license: "MIT", version: "4.0.1", source: URL(string: "https://github.com/bloc97/Anime4K"),
            content: "For 2D art and anime-style games",
        ),
        root: URL(fileURLWithPath: "/demo/shaders/anime4k-c"),
    )

    private func installSimulated(_ entry: ShaderPackages.Available) async -> ShaderPackages.Package? {
        EventLog.shared.log(.setup, "demo: shaders: would fetch \(entry.title)")
        for step in 1 ... 4 {
            try? await Task.sleep(for: .milliseconds(400))
            busy?.fraction = Double(step) / 4
        }
        let package = ShaderPackages.Package(
            manifest: .init(
                name: entry.name, title: entry.title, description: entry.description, license: entry.license,
                version: entry.version, source: entry.source, content: entry.content,
            ),
            root: URL(fileURLWithPath: "/demo/shaders/\(entry.name)"),
        )
        installed = (installed.filter { $0.name != entry.name } + [package])
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return package
    }
}
