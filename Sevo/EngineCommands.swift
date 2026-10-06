import ArgumentParser
import Foundation
import os
import Synchronization

// MARK: - engine

struct EngineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "engine",
        abstract: "Wine engines: Dormison releases and CrossOver.",
    )

    @Argument(help: "list | install [--file TARBALL-OR-FOLDER] | d3dmetal | use | channel [stable|beta] | check-manifest")
    var verb: String = "list"
    @Argument(
        help: "For use: the engine to switch to (a name from `sevo engine list`); for channel: stable (releases) or beta, the channel app and engine updates both follow; for check-manifest: the engine.json to check.",
    )
    var target: String?
    @Option(
        name: .customLong("channel"),
        help: "For install: take this channel's release instead of the Mac's setting (stable | beta).",
    ) var channelName: String?

    private func channel() throws -> UpdateChannel? {
        guard let channelName else { return nil }
        guard let channel = UpdateChannel(rawValue: channelName) else {
            Sevo.printError("--channel \(channelName): stable or beta")
            throw SevoExit.badInvocation
        }
        return channel
    }
    @Option(
        name: .customLong("sig"),
        help: "For check-manifest: the engine.json.sig to verify against the pinned key.",
    ) var signatureFile: String?
    @Option(
        name: .customLong("bottle"),
        help: "For use: the bottle to run (default: the current one).",
    ) var bottle: String?
    @Flag(
        name: .customLong("no-app"),
        help: "For use: drive the client from this process instead of through the daemon (debug); without it a stopped daemon is started to boot the engine.",
    ) var noApp = false
    @Option(
        name: .customLong("from"),
        help: "For d3dmetal: Apple's Game Porting Toolkit disk image, volume, or folder.",
    ) var from: String?
    @Option(
        name: .customLong("use"),
        help: "For d3dmetal: the version to run, or 'own' for the engine's own copy.",
    ) var use: String?
    @Option(
        name: .customLong("into"),
        help: "For d3dmetal: which installed engine to add it to (default: the active one).",
    ) var into: String?
    @Option(
        name: .customLong("manifest"),
        help: "Manifest URL override (default: the kagerou.glass manifest).",
    ) var manifest: String?
    @Option(
        name: .customLong("file"),
        help: "For install: an engine tarball (dormison-b<N>.tar.xz) or an engine folder on disk, in place of the download; a .sig beside a tarball is verified.",
    ) var file: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list":
            try await list()
        case "install":
            try await install()
        case "d3dmetal":
            try await addD3DMetal()
        case "use":
            try await use()
        case "channel":
            try setChannel()
        case "check-manifest":
            try checkManifest()
        default:
            Sevo.printError("engine \(verb): unknown verb (list | install | d3dmetal | use | channel | check-manifest)")
            throw SevoExit.badInvocation
        }
    }

    /// Reads or sets which channel this Mac takes app and engine updates
    /// from. The next engine install, the next engine update check and the
    /// app's next update check read it; nothing already installed changes.
    private func setChannel() throws {
        if let target {
            guard let channel = UpdateChannel(rawValue: target) else {
                Sevo.printError("engine channel \(target): stable or beta")
                throw SevoExit.badInvocation
            }
            Preferences.updateChannel = channel
            print("update channel: \(channel.rawValue) — the next app update check and engine install take it")
        } else {
            print("update channel: \(Preferences.updateChannel.rawValue)")
        }
    }

    /// The gate `publish-engine.sh` runs before it uploads a manifest: the
    /// file decodes with this build's decoder, every entry passes
    /// ``EngineManifest/problems()``, and with `--sig` the bytes verify
    /// against the key pinned in ``EngineSignature``. Exit 1 on any problem.
    private func checkManifest() throws {
        guard let target, !target.isEmpty else {
            Sevo.printError("engine check-manifest: name the engine.json to check")
            throw SevoExit.badInvocation
        }
        let path = URL(fileURLWithPath: (target as NSString).expandingTildeInPath)
        var problems: [String] = []
        var summary: [String: Any] = ["file": path.path]
        do {
            let data = try Data(contentsOf: path)
            let manifest = try EngineManifest.decode(data)
            problems = manifest.problems()
            summary["schema"] = manifest.schema
            summary["channels"] = manifest.channels.mapValues { $0.version }
            summary["components"] = (manifest.components ?? [:]).mapValues(\.count)
            summary["shaders"] = manifest.shaders?.count ?? 0
            if let signatureFile {
                let sigPath = (signatureFile as NSString).expandingTildeInPath
                do {
                    try EngineSignature.verify(
                        data, signatureFile: Data(contentsOf: URL(fileURLWithPath: sigPath)),
                        subject: path.lastPathComponent,
                    )
                    summary["signature"] = "verified"
                } catch {
                    problems.append("signature: \(error)")
                }
            }
        } catch {
            problems.append("decode: \(error)")
        }
        summary["problems"] = problems
        if asJSON {
            print(Sevo.json(summary, pretty: true))
        } else if problems.isEmpty {
            let named = summary["channels"] as? [String: String] ?? [:]
            var channels = named.sorted { $0.key < $1.key }.map { "\($0.key) → \($0.value)" }
            if named[UpdateChannel.stable.rawValue] == nil { channels.append("stable empty") }
            print("manifest ok: schema \(summary["schema"] ?? "?"), \(channels.joined(separator: ", "))"
                + ((summary["signature"] as? String).map { ", signature \($0)" } ?? ""))
        } else {
            for problem in problems {
                Sevo.printError("manifest: \(problem)")
            }
        }
        if !problems.isEmpty { throw SevoExit.failed }
    }

    /// Switches the active engine and restarts the client — the CLI face of
    /// Settings › Engine's picker plus Apply.
    private func use() async throws {
        guard let target, !target.isEmpty else {
            Sevo.printError("engine use: name the engine to switch to (sevo engine list)")
            throw SevoExit.badInvocation
        }
        let engine: Engine
        do {
            engine = try Engine.named(target)
        } catch {
            Sevo.printError("engine use: \(error)")
            throw SevoExit.badInvocation
        }
        guard engine.existsOnDisk else {
            Sevo.printError("engine \(target) is not installed — sevo engine list")
            throw SevoExit.badInvocation
        }
        try await handlingFailures {
            let outcome = try await ClientOps.useEngine(
                engine, version: target, bottle: bottle, noApp: noApp,
            ) { narrate($0, asJSON: asJSON) }
            await StatusReport.emit(outcome, asJSON: asJSON)
        }
    }

    /// Adds Apple's D3DMetal to the managed engine from the user's own copy
    /// of the Game Porting Toolkit — the CLI face of Settings › Graphics.
    private func addD3DMetal() async throws {
        // Toolkits live in one store for every engine; `--into` names the managed engine
        // whose Wine tree is reported, the active one without it.
        var version = into
        if version == nil, case let .managed(active) = Engine.active { version = active }
        let engine = D3DMetalInstaller.store
        let tree = version.flatMap { Engine.managedDirectory($0) }
        let label = version ?? "CrossOver"
        if let use {
            if use == "own" {
                D3DMetalInstaller.choose(version: nil)
            } else {
                guard let entry = D3DMetalInstaller.installed(inEngine: engine)
                    .first(where: { $0.version == use })
                else {
                    Sevo.printError("D3DMetal \(use) is not installed for \(label)")
                    throw SevoExit.badInvocation
                }
                // Record only: the next spawn stages both halves together
                // (``EngineRenderers/stage``). Placing the macOS half here
                // while the Windows half waits crosses versions.
                D3DMetalInstaller.choose(version: entry.version)
            }
            let launcher = CrossOverShadow.preparedLauncher()
            // Games spawn inside the client, which staged its toolkit when it
            // booted: the choice reaches them with the client's next boot.
            print("D3DMetal for \(label): \(use == "own" ? "the engine's own" : use)"
                + (launcher == nil ? "" : ", shadow tree ready")
                + " — in the client from its next boot: sevo client restart")
            return
        }
        guard let from else {
            let installed = D3DMetalInstaller.installed(inEngine: engine)
            let active = D3DMetalInstaller.active(inEngine: engine)
            if installed.isEmpty {
                print("no D3DMetal installed for \(label) — add one with: "
                    + "sevo engine d3dmetal --from <Game Porting Toolkit dmg>")
            }
            for entry in installed {
                let note = entry == active ? "  (selected)" : ""
                print(entry.version + note)
            }
            if active == nil, !installed.isEmpty { print("the engine's own  (selected)") }
            // The on-disk truth: what a game actually loads, both halves,
            // independent of what the picker recorded. A crossed tree here is
            // the silent 14 s boot death.
            if let tree, !installed.isEmpty {
                let placement = D3DMetalInstaller.placement(inEngine: tree)
                if let macOS = placement.macOS, placement.halvesAgree {
                    print("in the Wine tree: \(macOS)  (both halves)")
                } else if placement.macOS != nil || placement.windows != nil {
                    print("⚠ crossed tree: macOS half "
                        + "\(placement.macOS ?? "none"), Windows half "
                        + "\(placement.windows ?? "none") — start a game to restage")
                } else {
                    print("in the Wine tree: none yet (staged at the next launch)")
                }
            }
            return
        }
        do {
            let entry = try await D3DMetalInstaller.install(
                from: URL(fileURLWithPath: (from as NSString).expandingTildeInPath),
                intoEngine: engine,
            )
            D3DMetalInstaller.choose(version: entry.version)
            print("D3DMetal \(entry.version) installed for \(label)")
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
    }

    /// Downloads and installs the release on this Mac's update channel (or
    /// `--channel`'s) — the CLI face
    /// of the wizard's built-in-engine stage — or, with `--file`, installs
    /// the tarball or engine folder on disk, the route for a Mac the release
    /// feed does not reach and for a tree built here.
    private func install() async throws {
        if let file {
            let source = URL(fileURLWithPath: (file as NSString).expandingTildeInPath)
            do {
                let version = try await EngineInstaller.install(from: source, progress: phasePrinter())
                print("engine \(version) installed")
            } catch {
                Sevo.printError("engine install failed: \(error)")
                throw SevoExit.failed
            }
            return
        }
        let manifestURL = try manifest.map {
            guard let url = URL(string: $0) else {
                Sevo.printError("not a URL: \($0)")
                throw SevoExit.badInvocation
            }
            return url
        } ?? EngineManifest.url
        do {
            let fetched = try await EngineManifest.fetch(from: manifestURL)
            let wanted = try channel() ?? Preferences.updateChannel
            let release: EngineManifest.Release
            do {
                release = try fetched.requireRelease(for: wanted)
            } catch {
                Sevo.printError("\(error)")
                throw SevoExit.failed
            }
            guard !EngineInstaller.isInstalled(release) else {
                print("engine \(release.version) already installed")
                return
            }
            try await EngineInstaller.install(release, progress: phasePrinter())
            print("engine \(release.version) installed")
        } catch let code as ExitCode {
            throw code
        } catch {
            Sevo.printError("engine install failed: \(error)")
            Sevo.printError("with the tarball on disk: sevo engine install --file dormison-b<N>.tar.xz")
            throw SevoExit.failed
        }
    }

    /// Each new install phase once, on stderr; the fraction is not shown.
    private func phasePrinter() -> @Sendable (String, Double?) -> Void {
        let printed = OSAllocatedUnfairLock(initialState: "")
        return { phase, _ in
            let repeated = printed.withLock { last in
                defer { last = phase }
                return last == phase
            }
            guard !repeated else { return }
            FileHandle.standardError.write(Data((phase + "\n").utf8))
        }
    }

    private func list() async throws {
        let d = await SetupProbe.detect()
        var rows: [[String: Any]] = []
        for (name, cx) in [("crossover", d.crossover), ("crossover-preview", d.crossoverPreview)] {
            guard let cx else { continue }
            rows.append([
                "engine": name, "version": cx.version, "licensed": cx.licensed,
                "expires": cx.expires ?? NSNull(), "trial_expired": cx.trialExpired,
            ])
        }
        for version in d.managedEngineVersions {
            rows.append(["engine": "builtin", "version": version])
        }
        if asJSON {
            print(Sevo.json(rows, pretty: true))
        } else if rows.isEmpty {
            print("no engines")
        } else {
            for row in rows {
                print("\(row["engine"] ?? "?") \(row["version"] ?? "?")")
            }
        }
    }
}

/// Versions of what runs under the app: the renderers beside the engine's
/// own. The CLI face of Settings › Graphics › Renderer versions.
struct UpdateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "update",
        abstract: "Check for and switch renderer versions (DXMT, DXVK).",
        discussion: """
        check              what is installed, chosen and available for each renderer
        use <c> <version>  run that version from the next boot; 'default' resets to the engine's own
        install <c> <ref>  add a version: a release version from check, a URL, an archive, or a folder
        remove <c> <version>
        <c> is dxmt or dxvk.
        """,
    )

    @Argument(help: "check | use | install | remove") var verb: String = "check"
    @Argument var component: String?
    @Argument var reference: String?
    @Option(help: "For install: the version to file it under when it cannot be read from the name.")
    var version: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "check": try await check()
        case "use": try await use()
        case "install": try await install()
        case "remove": try remove()
        default:
            Sevo.printError("update \(verb): unknown verb (check | use | install | remove)")
            throw SevoExit.badInvocation
        }
    }

    private func resolveComponent() throws -> RendererVersions.Component {
        guard let component, let resolved = RendererVersions.Component(rawValue: component.lowercased()) else {
            Sevo.printError("name the renderer: dxmt or dxvk")
            throw SevoExit.badInvocation
        }
        return resolved
    }

    private func check() async throws {
        let manifest = try? await EngineManifest.fetch()
        let engine = Engine.active.root
        var report: [[String: Any]] = []
        for component in RendererVersions.Component.allCases {
            let installed = RendererVersions.installed(component).map(\.version)
            let chosen = RendererVersions.chosen(component)
            let defaultVersion = RendererVersions.defaultVersion(component, engine: engine)
            let releases = await RendererVersions.releases(component, manifest: manifest)
            let newer = RendererVersions.newerRelease(than: installed, default: defaultVersion, among: releases)
            report.append([
                "component": component.rawValue,
                "default": defaultVersion ?? NSNull(),
                "chosen": chosen ?? NSNull(),
                "installed": installed,
                "available": releases.map { ["version": $0.version, "tested": $0.tested, "url": $0.url.absoluteString] },
                "newer": newer?.version ?? NSNull(),
            ])
            if !asJSON {
                print("\(component.label)")
                print("  running:   \(chosen ?? "engine's own\(defaultVersion.map { " (\($0))" } ?? "")")")
                print("  installed: \(installed.isEmpty ? "none added" : installed.joined(separator: ", "))")
                let available = releases.map { "\($0.version)\($0.tested ? " (tested)" : "")" }
                print("  available: \(available.isEmpty ? "unknown — no release list reachable" : available.joined(separator: ", "))")
                if let newer { print("  newer:     \(newer.version)\(newer.tested ? ", tested with this engine" : ", untested")") }
            }
        }
        if asJSON {
            let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: data, as: UTF8.self))
        }
    }

    private func use() async throws {
        let component = try resolveComponent()
        guard let reference else {
            Sevo.printError("update use: name a version, or 'default'")
            throw SevoExit.badInvocation
        }
        if reference == "default" {
            RendererVersions.choose(component, version: nil)
            print("\(component.label): the engine's own, from the next Steam start")
            return
        }
        guard RendererVersions.installed(component).contains(where: { $0.version == reference }) else {
            Sevo.printError("\(component.label) \(reference) is not installed — sevo update install \(component.rawValue) \(reference)")
            throw SevoExit.badInvocation
        }
        RendererVersions.choose(component, version: reference)
        print("\(component.label): \(reference), from the next Steam start")
    }

    private func install() async throws {
        let component = try resolveComponent()
        guard let reference else {
            Sevo.printError("update install: a version from `sevo update check`, a URL, an archive, or a folder")
            throw SevoExit.badInvocation
        }
        var source: URL
        var sha256: String?
        var name = version
        if reference.hasPrefix("http://") || reference.hasPrefix("https://"), let url = URL(string: reference) {
            source = url
        } else if FileManager.default.fileExists(atPath: reference) {
            source = URL(fileURLWithPath: reference)
        } else {
            let manifest = try? await EngineManifest.fetch()
            let releases = await RendererVersions.releases(component, manifest: manifest)
            guard let release = releases.first(where: { $0.version == reference }) else {
                Sevo.printError("no \(component.label) release \(reference) — sevo update check lists them")
                throw SevoExit.badInvocation
            }
            source = release.url
            sha256 = release.sha256
            name = name ?? release.version
        }
        let entry = try await RendererVersions.install(component, from: source, version: name, sha256: sha256)
        RendererVersions.choose(component, version: entry.version)
        print("\(component.label) \(entry.version) installed at \(entry.root.path) and chosen for the next Steam start")
    }

    private func remove() throws {
        let component = try resolveComponent()
        guard let reference,
              let entry = RendererVersions.installed(component).first(where: { $0.version == reference }) else {
            Sevo.printError("update remove: name an installed version (sevo update check)")
            throw SevoExit.badInvocation
        }
        try RendererVersions.remove(entry)
        print("\(component.label) \(reference) moved to the Trash")
    }
}

/// The shader packages the presenter's upscaler can run. The CLI face of
/// Settings › Graphics › Upscalers.
struct ShadersCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shaders",
        abstract: "Shader packages for the upscaler: what is installed, what can be fetched.",
        discussion: """
        list             installed packages, then the ones that can be fetched
        install <name>   fetch a package from the catalog, or copy the app's bundled one
        remove <name>    move a package to the Trash; a setting naming it is left as it is
        A package is chosen with sevo bottle config upscaler <name>, or per game with \
        sevo app config <appid> upscaler <name>.
        """,
    )

    @Argument(help: "list | install | remove") var verb: String = "list"
    @Argument(help: "The package's name, as list prints it.") var name: String?
    @Flag(name: .customLong("json")) var asJSON = false

    func run() async throws {
        switch verb {
        case "list": try await list()
        case "install": try await install()
        case "remove": try remove()
        default:
            Sevo.printError("shaders \(verb): unknown verb (list | install | remove)")
            throw SevoExit.badInvocation
        }
    }

    private func list() async throws {
        ShaderPackages.ensureBundled()
        let installed = ShaderPackages.installed()
        let manifest = try? await EngineManifest.fetch()
        let catalog = ShaderPackages.catalog(manifest: manifest)
        let have = Set(installed.map(\.name))
        let available = catalog.filter { !have.contains($0.name) }
        if asJSON {
            print(Sevo.json([
                "installed": installed.map { package -> [String: Any] in
                    [
                        "name": package.name, "title": package.title, "version": package.manifest.version,
                        "license": package.manifest.license, "content": package.manifest.content,
                        "source": package.manifest.source?.absoluteString ?? NSNull(),
                        "path": package.root.path,
                    ]
                },
                "available": available.map { entry -> [String: Any] in
                    var row: [String: Any] = [
                        "name": entry.name, "title": entry.title, "version": entry.version,
                        "license": entry.license, "content": entry.content,
                        "source": entry.source?.absoluteString ?? NSNull(),
                        "size": entry.size ?? NSNull(),
                    ]
                    if case let .download(url, _, _) = entry.origin { row["url"] = url.absoluteString }
                    return row
                },
            ], pretty: true))
            return
        }
        print("installed")
        if installed.isEmpty { print("  none") }
        for package in installed {
            print("  \(package.name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(package.title) \(package.manifest.version) · \(package.manifest.license) — \(package.manifest.content)")
        }
        print("available")
        if available.isEmpty { print("  nothing further") }
        for entry in available {
            let size = entry.size.map { " · " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""
            print("  \(entry.name.padding(toLength: 12, withPad: " ", startingAt: 0)) "
                + "\(entry.title) \(entry.version) · \(entry.license)\(size) — \(entry.content)")
        }
    }

    private func install() async throws {
        guard let name else {
            Sevo.printError("shaders install: name a package (sevo shaders list)")
            throw SevoExit.badInvocation
        }
        let manifest = try? await EngineManifest.fetch()
        guard let entry = ShaderPackages.catalog(manifest: manifest).first(where: { $0.name == name }) else {
            Sevo.printError("no shader package named \(name) in the catalog — sevo shaders list")
            throw SevoExit.badInvocation
        }
        do {
            // One line per whole percent, so a 60-second download does not
            // scroll a thousand of them.
            let lastPercent = Mutex(-1)
            let package = try await ShaderPackages.install(entry) { fraction in
                let percent = fraction.map { Int($0 * 100) } ?? -1
                let changed = lastPercent.withLock { last -> Bool in
                    guard last != percent else { return false }
                    last = percent
                    return true
                }
                guard changed else { return }
                let suffix = percent >= 0 ? " \(percent)%" : ""
                FileHandle.standardError.write(Data("downloading \(entry.title)\(suffix)\n".utf8))
            }
            print("\(package.title) \(package.manifest.version) installed at \(package.root.path)")
        } catch {
            Sevo.printError("\(error)")
            throw SevoExit.failed
        }
    }

    private func remove() throws {
        guard let name, let package = ShaderPackages.installed().first(where: { $0.name == name }) else {
            Sevo.printError("shaders remove: name an installed package (sevo shaders list)")
            throw SevoExit.badInvocation
        }
        try ShaderPackages.remove(package)
        print("\(package.title) moved to the Trash")
    }
}
