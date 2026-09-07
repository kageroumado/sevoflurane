import Foundation
import Testing
@testable import Sevoflurane

/// The upscaler's place in the settings hierarchy: the values, the lines the
/// engine reads, and what the shader package store says is on offer.
struct UpscalerConfigTests {
    @Test
    func `the upscaler and the filter round-trip, and a later version's package name still reads`() throws {
        var values = ConfigValues.empty
        values.upscaler = "a-package-this-version-does-not-know"
        values.filter = .nearest
        let data = try JSONEncoder().encode(values)
        let back = try JSONDecoder().decode(ConfigValues.self, from: data)
        #expect(back == values)
        #expect(back.upscaler == "a-package-this-version-does-not-know")
        #expect(back.filter == .nearest)
    }

    @Test
    func `either key alone makes a level say something`() {
        var values = ConfigValues.empty
        #expect(!values.hasSettings)
        values.upscaler = UpscalerChoice.off.rawValue
        #expect(values.hasSettings)
        values = .empty
        values.filter = .bilinear
        #expect(values.hasSettings)
    }

    @Test
    func `nothing set anywhere means off, resampled with lanczos`() {
        #expect(GameConfig.defaults.upscaler == "off")
        #expect(GameConfig.defaults.filter == .lanczos)
        #expect(UpscalerChoice(rawValue: GameConfig.defaults.upscaler!) == .off)
    }

    @Test
    func `a game's file carries what the game sets, an explicit off included`() {
        var values = ConfigValues.empty
        values.name = "Example"
        values.upscaler = "off"
        values.filter = .nearest
        let lines = ConfigMaterializer.gameLines(42, values)
        #expect(lines.first == "# app 42 Example")
        #expect(lines.contains("SEVO_UPSCALER=off"))
        #expect(lines.contains("SEVO_FINAL_FILTER=nearest"))
        #expect(!lines.contains { $0.hasPrefix("SEVO_RESIZABLE_WINDOWS") })

        let inheriting = ConfigMaterializer.gameLines(42, .empty)
        #expect(!inheriting.contains { $0.hasPrefix("SEVO_UPSCALER") })
        #expect(!inheriting.contains { $0.hasPrefix("SEVO_FINAL_FILTER") })
    }

    @Test
    func `the fixed choices describe themselves without promising temporal upscaling`() {
        for choice in UpscalerChoice.allCases {
            #expect(!choice.label.isEmpty)
            #expect(!choice.detail.isEmpty)
            #expect(!choice.detail.localizedCaseInsensitiveContains("temporal"))
        }
        #expect(UpscalerChoice.metalfx.label == "MetalFX Spatial")
    }
}

/// The shader package store: what a package is, how the catalog is put
/// together, and what the picker lists.
struct ShaderPackagesTests {
    private let packageJSON = """
    {
      "name": "cunny-nvl",
      "title": "CuNNy NVL",
      "description": "A small convolutional upscaler.",
      "license": "LGPL-3.0-only",
      "version": "1",
      "source": "https://github.com/funnyplanter/CuNNy",
      "content": "Trained on visual-novel screenshots and illustrations"
    }
    """

    @Test
    func `package.json decodes, with or without a source`() throws {
        let manifest = try JSONDecoder().decode(ShaderPackages.Manifest.self, from: Data(packageJSON.utf8))
        #expect(manifest.name == "cunny-nvl")
        #expect(manifest.license == "LGPL-3.0-only")
        #expect(manifest.source?.host == "github.com")
        let bare = packageJSON.replacingOccurrences(of: "\"source\": \"https://github.com/funnyplanter/CuNNy\",\n", with: "")
        let without = try JSONDecoder().decode(ShaderPackages.Manifest.self, from: Data(bare.utf8))
        #expect(without.source == nil)
    }

    @Test
    func `a directory is a package when all three files are there`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderPackagesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("cunny-nvl")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(packageJSON.utf8).write(to: directory.appendingPathComponent("package.json"))
        try Data().write(to: directory.appendingPathComponent("graph.json"))
        #expect(ShaderPackages.read(directory) == nil)
        try Data().write(to: directory.appendingPathComponent("shaders.metallib"))
        let package = try #require(ShaderPackages.read(directory))
        #expect(package.name == "cunny-nvl")
        #expect(package.root == directory)
    }

    @Test
    func `a tarball's package is found flat or under one folder`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ShaderPackagesTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let nested = root.appendingPathComponent("cunny-nvl")
        try FileManager.default.createDirectory(at: nested.appendingPathComponent("source"), withIntermediateDirectories: true)
        try Data().write(to: nested.appendingPathComponent("package.json"))
        try Data().write(to: nested.appendingPathComponent("source/package.json"))
        #expect(ShaderPackages.packageDirectory(under: root) == nested)
        #expect(ShaderPackages.packageDirectory(under: root.appendingPathComponent("nowhere")) == nil)
    }

    private func entry(_ name: String, title: String, version: String = "1") -> ShaderPackages.Available {
        .init(
            name: name, title: title, description: "", content: "", license: "MIT", version: version,
            source: nil, origin: .download(url: URL(string: "https://example.invalid/\(name).tar.gz")!, sha256: nil, size: nil),
        )
    }

    @Test
    func `the catalog has one entry per name, the bundle's description winning`() {
        let merged = ShaderPackages.merge(
            bundled: [entry("anime4k-c", title: "Anime4K (bundled)")],
            manifest: [entry("anime4k-c", title: "Anime4K (manifest)"), entry("cunny-nvl", title: "CuNNy (manifest)")],
            builtIn: [entry("cunny-nvl", title: "CuNNy (built-in)"), entry("zzz", title: "Zed")],
        )
        #expect(merged.map(\.name).sorted() == ["anime4k-c", "cunny-nvl", "zzz"])
        #expect(merged.first { $0.name == "anime4k-c" }?.title == "Anime4K (bundled)")
        #expect(merged.first { $0.name == "cunny-nvl" }?.title == "CuNNy (manifest)")
    }

    @Test
    func `the picker lists the fixed choices, then installed packages, then downloads`() {
        let installed = ShaderPackages.Package(
            manifest: .init(
                name: "anime4k-c", title: "Anime4K", description: "d", license: "MIT", version: "1",
                source: nil, content: "c",
            ),
            root: URL(fileURLWithPath: "/tmp/anime4k-c"),
        )
        let catalog = [entry("anime4k-c", title: "Anime4K"), entry("cunny-nvl", title: "CuNNy NVL")]
        let choices = ShaderPackages.choices(installed: [installed], catalog: catalog)
        #expect(choices.map(\.token) == ["off", "lanczos", "metalfx", "anime4k-c", "cunny-nvl"])
        #expect(choices[3] == .installed(installed))
        if case .downloadable = choices[4] {} else { Issue.record("cunny-nvl should be a download") }

        #expect(ShaderPackages.choice(for: "metalfx", installed: [installed], catalog: catalog) == .fixed(.metalfx))
        #expect(ShaderPackages.choice(for: "nonsense", installed: [installed], catalog: catalog) == nil)
    }

    @Test
    func `the built-in catalog names the two packages with their licenses`() {
        let cunny = ShaderPackages.builtInCatalog.first { $0.name == "cunny-nvl" }
        #expect(cunny?.license == "LGPL-3.0-only")
        #expect(cunny?.size == nil)
        if case let .download(url, sha256, _)? = cunny?.origin {
            #expect(url.lastPathComponent == "cunny-nvl-1.tar.gz")
            #expect(sha256 == nil)
        } else {
            Issue.record("cunny-nvl is a download")
        }
        let anime = ShaderPackages.builtInCatalog.first { $0.name == "anime4k-c" }
        #expect(anime?.license == "MIT")
        #expect(anime?.origin == .bundled)
    }

    @Test
    func `the engine manifest lists shader packages in schema 2`() throws {
        let json = """
        {
          "schema": 2,
          "channels": {},
          "shaders": [
            {
              "name": "cunny-nvl", "title": "CuNNy NVL", "description": "d", "content": "c",
              "license": "LGPL-3.0-only", "version": "1",
              "url": "https://example.invalid/cunny-nvl-1.tar.gz", "sha256": "ab", "size": 12345
            }
          ]
        }
        """
        let manifest = try EngineManifest.decode(Data(json.utf8))
        let release = try #require(manifest.shaders?.first)
        #expect(release.name == "cunny-nvl")
        #expect(release.size == 12345)
        let catalog = ShaderPackages.catalog(manifest: manifest)
        let cunny = try #require(catalog.first { $0.name == "cunny-nvl" })
        #expect(cunny.size == 12345)
    }
}
