import Foundation

/// Versions of the two open-source renderers a managed engine can run other
/// than the one it shipped with.
///
/// An engine tarball carries one DXMT and one DXVK, baked into `dxmt/` and
/// `dxvk/` at its top; those are the defaults and are never touched. Every
/// other version — downloaded from a release, or added from a folder — lives
/// under `Renderers/<component>/<version>/` in the app's own store, in the
/// layout the engine's payload directories use (the 64-bit DLLs flat at the
/// top, the 32-bit ones in `i386-windows/`). A choice is one preference per
/// component; `nil` is the default, so "reset" is forgetting the choice. The
/// stager (``EngineRenderers``) reads the chosen directory on every boot,
/// which is when a change takes effect.
nonisolated enum RendererVersions {
    enum Component: String, CaseIterable, Sendable, Identifiable, Codable {
        case dxmt
        case dxvk

        var id: String {
            rawValue
        }

        var label: String {
            switch self {
            case .dxmt: "DXMT"
            case .dxvk: "DXVK"
            }
        }

        var renderer: Renderer {
            switch self {
            case .dxmt: .dxmt
            case .dxvk: .dxvk
            }
        }

        /// The GitHub project whose releases carry the builtin-flavored
        /// payload the engine loads.
        var repository: String {
            switch self {
            case .dxmt: "3Shain/dxmt"
            case .dxvk: "Gcenx/DXVK-macOS"
            }
        }

        /// The release asset that is the payload: DXMT's `-builtin.tar.gz`,
        /// DXVK-macOS's `…-builtin.tar.gz` (the plain tarballs carry DLLs
        /// Wine would treat as native and refuse to load as builtins).
        func isPayloadAsset(_ name: String) -> Bool {
            name.hasSuffix("-builtin.tar.gz")
        }

        /// A release tag or asset name reduced to the version people say:
        /// `dxmt-v0.80-builtin.tar.gz` → `0.80`,
        /// `dxvk-macOS-async-v1.10.3-20230507-repack-builtin.tar.gz` →
        /// `1.10.3-20230507-repack`.
        func version(from name: String) -> String {
            var text = name
            for suffix in [".tar.gz", ".tgz", ".tar.xz", ".zip", "-builtin"] where text.hasSuffix(suffix) {
                text = String(text.dropLast(suffix.count))
            }
            for prefix in ["dxmt-", "dxvk-macOS-async-", "dxvk-macOS-", "dxvk-", "v"] where text.hasPrefix(prefix) {
                text = String(text.dropFirst(prefix.count))
            }
            return text
        }

        fileprivate var preferenceKey: String {
            "rendererVersion.\(rawValue)"
        }
    }

    /// One version on disk.
    struct Installed: Equatable, Sendable, Identifiable {
        let component: Component
        let version: String
        let root: URL
        var id: String {
            version
        }
    }

    /// One version that can be fetched.
    struct Release: Equatable, Sendable, Identifiable {
        let component: Component
        let version: String
        let url: URL
        /// Named in Sevoflurane's manifest as run with the current engine.
        let tested: Bool
        let sha256: String?
        var id: String {
            version
        }
    }

    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Renderers")

    // MARK: - What is on disk

    static func installed(_ component: Component) -> [Installed] {
        let directory = root.appendingPathComponent(component.rawValue)
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles],
        )) ?? []
        return entries
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { Installed(component: component, version: $0.lastPathComponent, root: $0) }
            .sorted { $0.version.localizedStandardCompare($1.version) == .orderedAscending }
    }

    /// The version the engine shipped with, read from its `engine-info.json`
    /// (the release URL `package-engine.sh` records), or `nil` for an engine
    /// that does not say.
    static func defaultVersion(_ component: Component, engine: URL) -> String? {
        let info = engine.appendingPathComponent("engine-info.json")
        guard let data = try? Data(contentsOf: info),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = object[component.rawValue] as? String,
              let last = text.split(separator: "/").last
        else { return nil }
        return component.version(from: String(last))
    }

    // MARK: - The choice

    /// The chosen version, or `nil` for the engine's own.
    static func chosen(_ component: Component) -> String? {
        let value = Preferences.shared.string(forKey: component.preferenceKey)
        return value?.isEmpty == false ? value : nil
    }

    static func choose(_ component: Component, version: String?) {
        if let version {
            Preferences.shared.set(version, forKey: component.preferenceKey)
        } else {
            Preferences.shared.removeObject(forKey: component.preferenceKey)
        }
    }

    /// The payload directory the stager reads for this component: the chosen
    /// version when it is installed, else the engine's own.
    static func directory(_ component: Component, engine: URL) -> URL {
        if let version = chosen(component),
           let match = installed(component).first(where: { $0.version == version }) {
            return match.root
        }
        return engine.appendingPathComponent(component.rawValue)
    }

    /// Every version directory on disk, for the stager's bookkeeping of
    /// which files in the Wine tree are payloads.
    static func allDirectories() -> [URL] {
        Component.allCases.flatMap { installed($0).map(\.root) }
    }

    // MARK: - Installing

    struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }

    /// Adds a version from a release URL, a downloaded tarball, or a folder
    /// holding the DLLs, normalizing it into the payload layout. The version
    /// names the directory; when not given it is read from the file or
    /// folder name.
    static func install(
        _ component: Component, from source: URL, version: String? = nil,
        sha256: String? = nil,
    ) async throws -> Installed {
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-renderer-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        var local = source
        if let scheme = source.scheme, scheme == "http" || scheme == "https" {
            let (downloaded, response) = try await URLSession.shared.download(from: source)
            guard (response as? HTTPURLResponse).map({ (200 ..< 300).contains($0.statusCode) }) ?? true else {
                throw InstallError("\(source.host ?? "the server") answered \((response as? HTTPURLResponse)?.statusCode ?? 0)")
            }
            local = staging.appendingPathComponent(source.lastPathComponent)
            try manager.moveItem(at: downloaded, to: local)
        }
        if let sha256 {
            let actual = try EngineInstaller.sha256(of: local)
            guard actual == sha256.lowercased() else {
                throw InstallError("the download does not match its checksum")
            }
        }

        var payloadRoot = local
        if !((try? local.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false) {
            let extracted = staging.appendingPathComponent("extracted")
            try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
            guard run("/usr/bin/tar", ["-xf", local.path, "-C", extracted.path]) else {
                throw InstallError("\(local.lastPathComponent) could not be unpacked")
            }
            payloadRoot = extracted
        }

        guard let halves = locateHalves(under: payloadRoot) else {
            throw InstallError("no \(component.label) DLLs (dxgi.dll, d3d11.dll) found in \(source.lastPathComponent)")
        }
        let name = version ?? component.version(from: local.lastPathComponent)
        guard !name.isEmpty, !name.contains("/") else {
            throw InstallError("could not tell the version from \(local.lastPathComponent); pass one")
        }
        let destination = root.appendingPathComponent(component.rawValue).appendingPathComponent(name)
        if manager.fileExists(atPath: destination.path) {
            try manager.trashItem(at: destination, resultingItemURL: nil)
        }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try copyDLLs(from: halves.x86_64, to: destination)
        if let i386 = halves.i386 {
            let sub = destination.appendingPathComponent("i386-windows")
            try manager.createDirectory(at: sub, withIntermediateDirectories: true)
            try copyDLLs(from: i386, to: sub)
        }
        return Installed(component: component, version: name, root: destination)
    }

    static func remove(_ installed: Installed) throws {
        try FileManager.default.trashItem(at: installed.root, resultingItemURL: nil)
        if chosen(installed.component) == installed.version {
            choose(installed.component, version: nil)
        }
    }

    /// The directories holding each half's DLLs, found by the file every
    /// renderer ships: `dxgi.dll`. A directory named for 32-bit (`x32`,
    /// `i386-windows`) is that half; the other is the 64-bit one, the
    /// shallowest first when several qualify.
    static func locateHalves(under directory: URL) -> (x86_64: URL, i386: URL?)? {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles],
        ) else { return nil }
        var candidates: [URL] = []
        for case let file as URL in enumerator where file.lastPathComponent.lowercased() == "dxgi.dll" {
            candidates.append(file.deletingLastPathComponent())
        }
        let is32 = { (url: URL) -> Bool in
            let name = url.lastPathComponent.lowercased()
            return name == "x32" || name == "i386-windows" || name == "x86" || name == "win32"
        }
        let byDepth = { (a: URL, b: URL) in a.pathComponents.count < b.pathComponents.count }
        guard let x86_64 = candidates.filter({ !is32($0) }).sorted(by: byDepth).first else { return nil }
        let i386 = candidates.filter(is32).sorted(by: byDepth).first
        return (x86_64, i386)
    }

    private static func copyDLLs(from source: URL, to destination: URL) throws {
        let manager = FileManager.default
        let files = try manager.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
        for file in files where file.pathExtension.lowercased() == "dll" {
            try manager.copyItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
        }
    }

    // MARK: - What can be fetched

    /// Versions available to download: the ones Sevoflurane's manifest names
    /// as tested with the engine, and every builtin payload the project has
    /// released, newest first. Either source may be unreachable; the answer
    /// is whatever answered.
    static func releases(_ component: Component, manifest: EngineManifest?) async -> [Release] {
        var byVersion: [String: Release] = [:]
        for entry in manifest?.components?[component.rawValue] ?? [] {
            byVersion[entry.version] = Release(
                component: component, version: entry.version, url: entry.url, tested: true, sha256: entry.sha256,
            )
        }
        for release in await upstreamReleases(component) where byVersion[release.version] == nil {
            byVersion[release.version] = release
        }
        return byVersion.values.sorted { $0.version.localizedStandardCompare($1.version) == .orderedDescending }
    }

    /// The GitHub releases API for the component's project: tags and their
    /// payload assets.
    static func upstreamReleases(_ component: Component) async -> [Release] {
        var request = URLRequest(
            url: URL(string: "https://api.github.com/repos/\(component.repository)/releases?per_page=30")!,
        )
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Sevoflurane (https://kagerou.glass)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return [] }
        return list.compactMap { release in
            guard let assets = release["assets"] as? [[String: Any]] else { return nil }
            for asset in assets {
                guard let name = asset["name"] as? String, component.isPayloadAsset(name),
                      let link = asset["browser_download_url"] as? String, let url = URL(string: link)
                else { continue }
                return Release(component: component, version: component.version(from: name), url: url, tested: false, sha256: nil)
            }
            return nil
        }
    }

    /// The newest release that is newer than what the engine shipped and than
    /// anything installed — the "update available" a checker reports.
    static func newerRelease(
        than installedVersions: [String], default defaultVersion: String?, among releases: [Release],
    ) -> Release? {
        let have = installedVersions + [defaultVersion].compactMap(\.self)
        return releases.first { release in
            have.allSatisfy { $0.localizedStandardCompare(release.version) == .orderedAscending }
        }
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
