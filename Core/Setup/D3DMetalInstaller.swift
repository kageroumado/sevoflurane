import AppKit
import Foundation

/// Adds Apple's D3DMetal to a managed engine from the user's own copy of the
/// Game Porting Toolkit.
///
/// Apple's evaluation environment is not redistributable, so the user points
/// the app at the disk image they downloaded, as with Whisky. What lands is
/// what Apple's Read Me installs: `redist/lib/` (the framework, the Windows
/// DLLs and the Wine unix libraries that bind them).
///
/// Versions live side by side under `d3dmetal/<version>/` in Apple's own
/// shape: the `.so` files are symlinks into `../../external/`, so splitting
/// them from the framework leaves them dangling. The newest installed version
/// is the default, because the betas are where the Direct3D 12 work lands.
nonisolated enum D3DMetalInstaller {
    struct Installed: Equatable, Sendable, Comparable {
        /// As Apple names it: "3.0", "4.0 beta 2".
        let version: String
        let root: URL

        /// Newest last; a beta sorts after its release of the same number.
        static func < (lhs: Installed, rhs: Installed) -> Bool {
            lhs.version.compare(rhs.version, options: .numeric) == .orderedAscending
        }
    }

    enum InstallError: Error, CustomStringConvertible {
        case notAToolkit(String)
        case attachFailed(String)
        case copyFailed(String)

        var description: String {
            switch self {
            case let .notAToolkit(path):
                "\(path) does not contain Apple's evaluation environment "
                    + "(no redist/lib/external/D3DMetal.framework inside)"
            case let .attachFailed(detail): "could not open the disk image: \(detail)"
            case let .copyFailed(detail): "could not install D3DMetal: \(detail)"
            }
        }
    }

    /// The one toolkit store for every engine, in an engine's layout
    /// (`d3dmetal/<version>`), so a newly installed engine finds the user's
    /// toolkits; CrossOver reaches it through ``CrossOverShadow``.
    static let sharedRoot = AppIdentity.supportFolder
        .appendingPathComponent("D3DMetal")

    /// The toolkit store every lookup and install goes to.
    static var store: URL { sharedRoot }

    /// ``adoptEngineToolkits(from:into:)`` over every installed managed engine, logged.
    static func adoptInstalledEnginesToolkits() {
        let engines = SetupProbe.managedEngineVersions().map(Engine.managedRoot.appendingPathComponent)
        for line in adoptEngineToolkits(from: engines).logLines { SetupLog.log(line) }
    }

    /// What ``adoptEngineToolkits(from:into:)`` did with each engine's toolkits.
    struct Adoption: Equatable, Sendable {
        /// Versions the store lacked, moved into it from an engine, oldest first.
        var moved: [String] = []
        /// How many engines a version was moved out of.
        var movedFrom = 0
        /// Versions the store already had, whose engine copies went to the Trash, oldest first.
        var trashed: [String] = []
        /// How many engines' copies went to the Trash.
        var trashedFrom = 0

        /// One line for what moved and one for what went to the Trash.
        var logLines: [String] {
            var lines: [String] = []
            if !moved.isEmpty {
                lines.append("D3DMetal \(Self.list(moved)) moved into the shared toolkit store from "
                    + (movedFrom == 1 ? "1 engine" : "\(movedFrom) engines"))
            }
            if !trashed.isEmpty {
                lines.append("D3DMetal \(Self.list(trashed)): the shared toolkit store already had "
                    + (trashed.count == 1 ? "it" : "them") + ", so "
                    + (trashedFrom == 1 ? "the engine's own copy" : "\(trashedFrom) engines' own copies")
                    + " went to the Trash")
            }
            return lines
        }

        /// `3.0`, `3.0 and 4.0 beta 2`, `2.1, 3.0 and 4.0 beta 2`.
        private static func list(_ versions: [String]) -> String {
            guard let last = versions.last, versions.count > 1 else { return versions.first ?? "" }
            return versions.dropLast().joined(separator: ", ") + " and " + last
        }
    }

    /// Moves the toolkits engines carry in their own `d3dmetal/` into the
    /// store, trashing an engine's copy of a version the store already has.
    @discardableResult
    static func adoptEngineToolkits(from engines: [URL], into store: URL = store) -> Adoption {
        let manager = FileManager.default
        var moved: Set<String> = [], trashed: Set<String> = []
        var movedFrom = 0, trashedFrom = 0
        for engine in engines {
            var movedHere = false, trashedHere = false
            for toolkit in installed(inEngine: engine) {
                let destination = store.appendingPathComponent("d3dmetal").appendingPathComponent(toolkit.version)
                if manager.fileExists(atPath: destination.path) {
                    if (try? manager.trashItem(at: toolkit.root, resultingItemURL: nil)) != nil {
                        trashed.insert(toolkit.version)
                        trashedHere = true
                    }
                    continue
                }
                try? manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if (try? manager.moveItem(at: toolkit.root, to: destination)) != nil {
                    moved.insert(toolkit.version)
                    movedHere = true
                }
            }
            if movedHere { movedFrom += 1 }
            if trashedHere { trashedFrom += 1 }
        }
        func ordered(_ versions: Set<String>) -> [String] {
            versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
        }
        return Adoption(moved: ordered(moved), movedFrom: movedFrom, trashed: ordered(trashed), trashedFrom: trashedFrom)
    }

    // MARK: - What is installed

    static func installed(inEngine engine: URL) -> [Installed] {
        let root = engine.appendingPathComponent("d3dmetal")
        let versions = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey],
        )) ?? []
        return versions
            .filter {
                FileManager.default.fileExists(
                    atPath: $0.appendingPathComponent(
                        "lib/external/D3DMetal.framework",
                    ).path,
                )
            }
            .map { Installed(version: $0.lastPathComponent, root: $0) }
            .sorted()
    }

    /// The Windows DLLs a bottle needs staged for this version.
    static func windowsLibraries(of installed: Installed) -> URL {
        installed.root.appendingPathComponent("lib/wine/x86_64-windows")
    }

    /// Copies a version's macOS side (the framework and the `.so` stubs that
    /// link to it) into the Wine tree at Apple's relative paths. The tree's
    /// copy is what a game runs; every boot re-asserts it through
    /// ``EngineRenderers/stage``.
    static func place(_ installed: Installed, inEngine engine: URL) throws {
        let wineLib = engine.appendingPathComponent("wine/lib")
        // The store has no Wine tree; its shadow tree points at the version.
        guard FileManager.default.fileExists(
            atPath: engine.appendingPathComponent("wine").path,
        ) else { return }
        do {
            try copyContents(
                of: installed.root.appendingPathComponent("lib/external"),
                into: wineLib.appendingPathComponent("external"),
            )
            try copyContents(
                of: installed.root.appendingPathComponent("lib/wine/x86_64-unix"),
                into: wineLib.appendingPathComponent("wine/x86_64-unix"),
            )
        } catch {
            throw InstallError.copyFailed(error.localizedDescription)
        }
    }

    /// Whether the Wine tree holds this version, comparing byte for byte the
    /// two files that differ between versions.
    static func isPlaced(_ installed: Installed, inEngine engine: URL) -> Bool {
        let manager = FileManager.default
        let tree = engine.appendingPathComponent("wine/lib/external")
        let own = installed.root.appendingPathComponent("lib/external")
        return identifyingFiles.allSatisfy { relative in
            manager.contentsEqual(
                atPath: tree.appendingPathComponent(relative).path,
                andPath: own.appendingPathComponent(relative).path,
            )
        }
    }

    /// Relative to `lib/external`.
    private static let identifyingFiles = [
        "libd3dshared.dylib",
        "D3DMetal.framework/Versions/A/D3DMetal",
    ]

    // MARK: - On-disk truth

    /// The version whose **macOS half** is in the Wine tree, matched by content.
    static func placedMacOSVersion(inEngine engine: URL) -> Installed? {
        placementCandidates(inEngine: engine).first { isPlaced($0, inEngine: engine) }
    }

    /// The version whose **Windows half** (the PE DLLs) fills the engine's
    /// tree, matched by content, or `nil` when none matches.
    static func placedWindowsVersion(inEngine engine: URL) -> Installed? {
        let canonical = engine.appendingPathComponent("wine/lib/wine/x86_64-windows")
        let manager = FileManager.default
        return placementCandidates(inEngine: engine).first { version in
            let own = windowsLibraries(of: version)
            let dlls = (try? manager.contentsOfDirectory(
                at: own, includingPropertiesForKeys: nil,
            ))?.filter { $0.pathExtension.lowercased() == "dll" } ?? []
            guard !dlls.isEmpty else { return false }
            return dlls.allSatisfy { dll in
                manager.contentsEqual(
                    atPath: dll.path,
                    andPath: canonical.appendingPathComponent(dll.lastPathComponent).path,
                )
            }
        }
    }

    /// The engine's own `d3dmetal/` versions, then the shared store's.
    private static func placementCandidates(inEngine engine: URL) -> [Installed] {
        let own = installed(inEngine: engine)
        return own + installed(inEngine: store).filter { shared in
            !own.contains { $0.version == shared.version }
        }
    }

    /// Both halves in the tree. `halvesAgree` false is the crossed state that
    /// silently kills the client 14 s into boot.
    struct Placement: Equatable {
        let macOS: String?
        let windows: String?
        var halvesAgree: Bool { macOS != nil && macOS == windows }
    }

    static func placement(inEngine engine: URL) -> Placement {
        Placement(
            macOS: placedMacOSVersion(inEngine: engine)?.version,
            windows: placedWindowsVersion(inEngine: engine)?.version,
        )
    }

    /// The bridge dylib the `.so` stubs resolve to and ntdll opens by path.
    static func bridgeLibrary(inEngine engine: URL) -> URL {
        engine.appendingPathComponent("wine/lib/external/libd3dshared.dylib")
    }

    /// The version a game gets: the user's choice when still installed,
    /// otherwise the newest, or `nil` when they chose the engine's own.
    static func active(inEngine engine: URL, preferences: UserDefaults = Preferences.shared) -> Installed? {
        let chosen = preferences.string(forKey: versionKey)
        if chosen == engineOwn { return nil }
        let available = installed(inEngine: engine)
        if let chosen, let match = available.first(where: { $0.version == chosen }) {
            return match
        }
        return available.last
    }

    /// `nil` asks for the engine's own copy — CrossOver's, or none at all.
    static func choose(version: String?) {
        Preferences.shared.set(version ?? engineOwn, forKey: versionKey)
    }

    /// Distinguishable from "never chosen", which still means "the newest".
    private static let engineOwn = ""

    private static let versionKey = "d3dmetalVersion"

    // MARK: - Installing

    /// Copies D3DMetal out of `source` (a toolkit disk image, a mounted
    /// volume, or an unpacked copy) into `engine` and answers the version.
    /// Installing chooses nothing; a caller records a pick with
    /// ``choose(version:)``.
    @concurrent
    static func install(from source: URL, intoEngine engine: URL) async throws -> Installed {
        var attached: [URL] = []
        defer { for volume in attached.reversed() {
            detach(volume)
        } }

        var searchRoot = source
        if source.pathExtension.lowercased() == "dmg" {
            let volume = try await attach(source)
            attached.append(volume)
            searchRoot = volume
        }
        // The toolkit nests "Evaluation environment for Windows games <version>.dmg".
        if redistLib(under: searchRoot) == nil,
           let inner = innerImage(under: searchRoot) {
            let volume = try await attach(inner)
            attached.append(volume)
            searchRoot = volume
        }
        guard let lib = redistLib(under: searchRoot) else {
            throw InstallError.notAToolkit(source.path)
        }

        let version = version(ofVolume: searchRoot)
        let destination = engine
            .appendingPathComponent("d3dmetal")
            .appendingPathComponent(version)
        let manager = FileManager.default
        do {
            if manager.fileExists(atPath: destination.path) {
                try manager.removeItem(at: destination)
            }
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            // Kept whole, per Apple's `ditto redist/lib/ .`.
            try manager.copyItem(at: lib, to: destination.appendingPathComponent("lib"))
        } catch {
            try? manager.removeItem(at: destination)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        // Never stage here: the next spawn stages both halves
        // (``EngineRenderers/stage``), so a mid-session install cannot cross
        // this dylib with the running tree's DLLs.
        return Installed(version: version, root: destination)
    }

    // MARK: - Reading the image

    /// `redist/lib` inside a mounted toolkit, identified by the framework.
    private static func redistLib(under root: URL) -> URL? {
        let candidate = root.appendingPathComponent("redist/lib")
        let framework = candidate.appendingPathComponent("external/D3DMetal.framework")
        return FileManager.default.fileExists(atPath: framework.path) ? candidate : nil
    }

    private static func innerImage(under root: URL) -> URL? {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
        )) ?? []
        return contents.first {
            $0.pathExtension.lowercased() == "dmg"
                && $0.lastPathComponent.localizedCaseInsensitiveContains("evaluation")
        }
    }

    /// Apple writes the version into the volume name — "Evaluation
    /// environment for Windows games 4.0 beta 2".
    private static func version(ofVolume volume: URL) -> String {
        let name = volume.lastPathComponent
        guard let range = name.range(
            of: #"[0-9]+\.[0-9]+( beta [0-9]+)?"#, options: .regularExpression,
        ) else { return name }
        return String(name[range])
    }

    private static func attach(_ image: URL) async throws -> URL {
        let result = await Subprocess.run(
            "/usr/bin/hdiutil",
            ["attach", "-nobrowse", "-readonly", "-plist", image.path],
            capture: .stdout, timeout: .seconds(120),
        )
        guard result.status == 0,
              let data = result.output.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil,
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]],
              let mount = entities.compactMap({ $0["mount-point"] as? String }).first
        else { throw InstallError.attachFailed(result.output.suffix(200).description) }
        return URL(fileURLWithPath: mount)
    }

    /// Waits, because the outer image cannot detach until the inner one has.
    private static func detach(_ volume: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["detach", "-quiet", volume.path]
        try? process.run()
        process.waitUntilExit()
    }

    private static func copyContents(of directory: URL, into destination: URL) throws {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        ) else { return }
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        for item in items {
            let target = destination.appendingPathComponent(item.lastPathComponent)
            // Unconditional: `fileExists` follows symlinks, and the target can
            // be a dangling one.
            try? manager.removeItem(at: target)
            try manager.copyItem(at: item, to: target)
        }
    }
}
