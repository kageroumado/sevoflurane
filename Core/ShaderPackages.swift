import Foundation

/// Shader packages the built-in engine's presenter runs as the upscaler
/// (dormison winemac.drv, `Upscaler` naming a package directory).
///
/// A package is a directory under `~/Library/Application
/// Support/Sevoflurane/Shaders/<name>/` holding `package.json`, `graph.json`
/// (its passes), `shaders.metallib`, `LICENSE` and `source/`; the engine
/// finds it through `SEVO_SHADER_DIR`. Packages come from the app bundle,
/// the engine manifest's `shaders` list, and ``builtInCatalog``. A removed
/// package stays chosen, and the driver falls back to Lanczos.
nonisolated enum ShaderPackages {
    /// `package.json`.
    struct Manifest: Codable, Equatable, Sendable {
        let name: String
        let title: String
        let description: String
        /// SPDX identifier.
        let license: String
        let version: String
        /// The upstream project.
        let source: URL?
        /// What it is trained on, or good at.
        let content: String
    }

    /// One package in the store.
    struct Package: Equatable, Sendable, Identifiable {
        let manifest: Manifest
        let root: URL

        var id: String {
            manifest.name
        }

        var name: String {
            manifest.name
        }

        var title: String {
            manifest.title
        }
    }

    /// One package that can be put in the store.
    struct Available: Equatable, Sendable, Identifiable {
        enum Origin: Equatable, Sendable {
            /// Shipped inside the app bundle, under `Resources/Shaders/<name>/`.
            case bundled
            /// A tarball holding the package directory.
            case download(url: URL, sha256: String?, size: Int64?)
        }

        let name: String
        let title: String
        let description: String
        let content: String
        let license: String
        let version: String
        let source: URL?
        let origin: Origin

        var id: String {
            name
        }

        /// The download's size when the catalog knows it.
        var size: Int64? {
            if case let .download(_, _, size) = origin { size } else { nil }
        }
    }

    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Shaders")

    /// The files a package directory needs.
    static let requiredFiles = ["package.json", "graph.json", "shaders.metallib"]

    /// The packages released before the engine manifest listed them.
    static let builtInCatalog: [Available] = [
        Available(
            name: "cunny-nvl",
            title: "CuNNy NVL",
            description: "CuNNy's NVL weights, a small neural upscaler for visual novels and art.",
            content: "Trained on visual-novel screenshots and illustrations",
            license: "LGPL-3.0-only",
            version: "1",
            source: URL(string: "https://github.com/funnyplanter/CuNNy"),
            origin: .download(
                url: URL(string: "https://github.com/kageroumado/dormison/releases/download/shaders/cunny-nvl-1.tar.gz")!,
                sha256: "e79a2e011f18c4fb1e2e01dff11ff8dced2c0e4f0fd73576d36bdfdfb6b1f026", size: 65585,
            ),
        ),
        Available(
            name: "anime4k-c",
            title: "Anime4K",
            description: "Anime4K mode C. Removes noise while it upscales, for clean sources.",
            content: "For 2D art and anime-style games",
            license: "MIT",
            version: "4.0.1",
            source: URL(string: "https://github.com/bloc97/Anime4K"),
            origin: .download(
                url: URL(string: "https://github.com/kageroumado/dormison/releases/download/shaders/anime4k-c-4.0.1.tar.gz")!,
                sha256: "59da9be19e41dc0bc58f3d96b2d399a91cf01d8ec0e14c82f14c2f3ce1dfe3b0", size: 37337,
            ),
        ),
    ]

    // MARK: - What is in the store

    /// Every valid package in the store, by title.
    static func installed() -> [Package] {
        directories(under: root)
            .compactMap(read)
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    /// The package at a directory, or `nil` when it is not one.
    static func read(_ directory: URL) -> Package? {
        let manager = FileManager.default
        guard requiredFiles.allSatisfy({ manager.fileExists(atPath: directory.appendingPathComponent($0).path) }),
              let data = try? Data(contentsOf: directory.appendingPathComponent("package.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data)
        else { return nil }
        return Package(manifest: manifest, root: directory)
    }

    // MARK: - What the bundle ships

    /// The app bundle's `Resources/Shaders/`, or `nil` for a build without one.
    static var bundledRoot: URL? {
        BundledResources.url("Shaders")
    }

    /// The packages inside the app bundle.
    static func bundled() -> [Package] {
        guard let bundledRoot else { return [] }
        return directories(under: bundledRoot).compactMap(read)
    }

    /// Copies each bundled package into the store when absent there or older
    /// by version. Run at app start and before a picker lists packages.
    static func ensureBundled() {
        let manager = FileManager.default
        for package in bundled() {
            let destination = root.appendingPathComponent(package.name)
            if let present = read(destination),
               present.manifest.version.localizedStandardCompare(package.manifest.version) != .orderedAscending {
                continue
            }
            try? manager.createDirectory(at: root, withIntermediateDirectories: true)
            if manager.fileExists(atPath: destination.path) {
                try? manager.trashItem(at: destination, resultingItemURL: nil)
            }
            try? manager.copyItem(at: package.root, to: destination)
        }
    }

    // MARK: - What can be fetched

    /// Everything that can be put in the store, installed or not.
    static func catalog(manifest: EngineManifest?) -> [Available] {
        merge(
            bundled: bundled().map(available(bundled:)),
            manifest: manifest?.shaders?.map(available(release:)) ?? [],
            builtIn: builtInCatalog.filter { entry in
                // A "bundled" built-in entry needs a build that carries it.
                if case .bundled = entry.origin { bundled().contains { $0.name == entry.name } } else { true }
            },
        )
    }

    /// One entry per name, by title; the bundle wins over the manifest, which
    /// wins over the built-in catalog.
    static func merge(bundled: [Available], manifest: [Available], builtIn: [Available]) -> [Available] {
        var byName: [String: Available] = [:]
        for entry in builtIn + manifest + bundled {
            byName[entry.name] = entry
        }
        return byName.values.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func available(bundled package: Package) -> Available {
        Available(
            name: package.name, title: package.title, description: package.manifest.description,
            content: package.manifest.content, license: package.manifest.license,
            version: package.manifest.version, source: package.manifest.source, origin: .bundled,
        )
    }

    private static func available(release: EngineManifest.ShaderRelease) -> Available {
        Available(
            name: release.name, title: release.title, description: release.description,
            content: release.content, license: release.license, version: release.version,
            source: release.source,
            origin: .download(url: release.url, sha256: release.sha256, size: release.size),
        )
    }

    // MARK: - Choices

    /// One entry of the upscaler picker.
    enum Choice: Equatable, Sendable, Identifiable {
        case fixed(UpscalerChoice)
        case installed(Package)
        case downloadable(Available)

        /// What the settings hierarchy stores for this choice.
        var token: String {
            switch self {
            case let .fixed(choice): choice.rawValue
            case let .installed(package): package.name
            case let .downloadable(entry): entry.name
            }
        }

        var id: String {
            token
        }

        var label: String {
            switch self {
            case let .fixed(choice): choice.label
            case let .installed(package): package.title
            case let .downloadable(entry): entry.title
            }
        }

        var detail: String {
            switch self {
            case let .fixed(choice): choice.detail
            case let .installed(package): InterfaceCopy.localized(package.manifest.description)
            case let .downloadable(entry): InterfaceCopy.localized(entry.description)
            }
        }
    }

    /// The fixed choices, the installed packages, then the uninstalled
    /// catalog packages.
    static func choices(installed: [Package], catalog: [Available]) -> [Choice] {
        let have = Set(installed.map(\.name))
        return UpscalerChoice.allCases.map(Choice.fixed)
            + installed.map(Choice.installed)
            + catalog.filter { !have.contains($0.name) }.map(Choice.downloadable)
    }

    /// The choice an upscaler token names, or `nil`.
    static func choice(for token: String, installed: [Package], catalog: [Available]) -> Choice? {
        choices(installed: installed, catalog: catalog).first { $0.token == token }
    }

    // MARK: - Installing

    struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    /// Copies or downloads, verifies and unpacks a package into the store,
    /// trashing one of the same name. `progress` is the download fraction,
    /// `nil` while the size is unknown.
    @concurrent
    static func install(
        _ available: Available, progress: (@Sendable (Double?) -> Void)? = nil,
    ) async throws -> Package {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-shader-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let unpacked: URL
        switch available.origin {
        case .bundled:
            guard let source = bundled().first(where: { $0.name == available.name })?.root else {
                throw InstallError("\(available.title) is not inside this copy of the app")
            }
            unpacked = staging.appendingPathComponent(available.name)
            try manager.copyItem(at: source, to: unpacked)
        case let .download(url, sha256, size):
            let tarball = staging.appendingPathComponent(url.lastPathComponent)
            try await download(url, to: tarball, expectedSize: size, progress: progress)
            if let sha256 {
                let actual = try FileDigest.sha256(of: tarball)
                guard actual == sha256.lowercased() else {
                    throw InstallError("the download of \(available.title) does not match its checksum")
                }
            }
            let extracted = staging.appendingPathComponent("extracted")
            try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
            guard run("/usr/bin/tar", ["-xf", tarball.path, "-C", extracted.path]) else {
                throw InstallError("\(url.lastPathComponent) could not be unpacked")
            }
            guard let found = packageDirectory(under: extracted) else {
                throw InstallError("\(url.lastPathComponent) is missing "
                    + requiredFiles.joined(separator: ", "))
            }
            unpacked = found
        }
        guard let package = read(unpacked) else {
            throw InstallError("\(available.title) is missing one of \(requiredFiles.joined(separator: ", ")), "
                + "or its package.json does not read")
        }
        let destination = root.appendingPathComponent(available.name)
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        if manager.fileExists(atPath: destination.path) {
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.moveItem(at: unpacked, to: destination)
        return Package(manifest: package.manifest, root: destination)
    }

    /// Moves a package to the Trash; settings naming it stay.
    static func remove(_ package: Package) throws {
        try FileManager.default.trashItem(at: package.root, resultingItemURL: nil)
    }

    /// The shallowest directory holding a `package.json`.
    static func packageDirectory(under directory: URL) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
        ) else { return nil }
        var candidates: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent == "package.json" {
            candidates.append(file.deletingLastPathComponent())
        }
        return candidates.min { $0.pathComponents.count < $1.pathComponents.count }
    }

    /// Streams a download to a file, reporting progress against the server's
    /// length, else the catalog's.
    private static func download(
        _ url: URL, to file: URL, expectedSize: Int64?, progress: (@Sendable (Double?) -> Void)?,
    ) async throws {
        var request = URLRequest(url: url)
        request.setValue("Sevoflurane (https://kagerou.glass)", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            throw InstallError("\(url.host ?? "the server") answered \(http.statusCode)")
        }
        let total = response.expectedContentLength > 0 ? response.expectedContentLength : (expectedSize ?? 0)
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else {
            throw InstallError("could not create \(file.lastPathComponent)")
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        let chunk = 1 << 16
        var buffer = Data(capacity: chunk)
        var received: Int64 = 0
        progress?(total > 0 ? 0 : nil)
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= chunk else { continue }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            progress?(total > 0 ? min(1, Double(received) / Double(total)) : nil)
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
        }
        progress?(1)
    }

    private static func directories(under directory: URL) -> [URL] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return entries.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    @discardableResult
    private static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }
}
