import AppKit
import Foundation

/// Adds Apple's D3DMetal to a managed engine from the user's own copy of the
/// Game Porting Toolkit.
///
/// Apple's evaluation environment is not ours to redistribute, so the managed
/// engine ships without it and the user points the app at the disk image they
/// downloaded — the same arrangement Whisky uses. What lands on disk is what
/// Apple's own Read Me says to install: `redist/lib/` copied over the engine's
/// `lib/`, which is the framework, the Windows DLLs, and the Wine unix
/// libraries that bind them.
///
/// More than one version can be installed at once. They live side by side
/// under `d3dmetal/<version>/`, keeping Apple's own directory shape — the
/// `.so` files there are symlinks into `../../external/`, so a layout that
/// splits them from the framework leaves them dangling. Activating a version
/// copies those two directories into the Wine tree, where the links resolve
/// exactly as Apple intends.
///
/// The newest installed version is the one a game gets unless the user says
/// otherwise: Apple ships releases and betas in parallel, and the beta is
/// where the Direct3D 12 work lands.
nonisolated enum D3DMetalInstaller {
    struct Installed: Equatable, Sendable, Comparable {
        /// As Apple names it: "3.0", "4.0 beta 2".
        let version: String
        let root: URL

        /// Newest last. A beta of the same number sorts *after* its release,
        /// because that is the order the work lands in.
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

    /// Where toolkits live when they are not inside a managed engine — the
    /// versions CrossOver can be pointed at through ``CrossOverShadow``.
    static let sharedRoot = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/D3DMetal")

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

    /// Puts a version's macOS side into the Wine tree that loads it: the
    /// framework beside the `.so` stubs that link to it, at the relative
    /// paths Apple's own instructions assume (`ditto redist/lib/ .`).
    ///
    /// The stubs are symlinks to `lib/external/libd3dshared.dylib`, so the
    /// copy in the tree is the D3DMetal a game runs whatever the picker
    /// says — every boot re-asserts it through ``EngineRenderers/stage``.
    static func place(_ installed: Installed, inEngine engine: URL) throws {
        let wineLib = engine.appendingPathComponent("wine/lib")
        // A store that is not an engine has no Wine tree to populate: the
        // shadow tree points at the version's own directory instead.
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

    /// Whether the Wine tree holds this version: the bridge dylib and the
    /// framework binary are the two files that differ between versions, and
    /// both are compared byte for byte. A tree swapped by hand answers false
    /// and is put right at the next boot.
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

    /// The version whose **macOS half** is in the Wine tree right now, matched
    /// by content — the truth the picker's record is checked against.
    static func placedMacOSVersion(inEngine engine: URL) -> Installed? {
        installed(inEngine: engine).first { isPlaced($0, inEngine: engine) }
    }

    /// The version whose **Windows half** (the PE DLLs) fills the engine's
    /// canonical tree, matched by content. `nil` when nothing matches — a
    /// crossed tree, or one a non-D3DMetal renderer staged.
    static func placedWindowsVersion(inEngine engine: URL) -> Installed? {
        let canonical = engine.appendingPathComponent("wine/lib/wine/x86_64-windows")
        let manager = FileManager.default
        return installed(inEngine: engine).first { version in
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

    /// What is actually in the tree, both halves. `halvesAgree` false is the
    /// crossed state that silently kills the client 14 s into boot.
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

    /// The bridge dylib inside a managed engine's Wine tree — the file the
    /// `.so` stubs resolve to, and the one ntdll opens by path.
    static func bridgeLibrary(inEngine engine: URL) -> URL {
        engine.appendingPathComponent("wine/lib/external/libd3dshared.dylib")
    }

    /// The version a game gets: the user's choice when it is still
    /// installed, otherwise the newest — unless they have asked for the
    /// engine's own, which is a choice and not an absence.
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

    /// Copies D3DMetal out of `source` — a Game Porting Toolkit disk image, a
    /// mounted volume, or an unpacked copy of either — into `engine`.
    /// Answers the version it installed.
    ///
    /// Installing chooses nothing: with no choice recorded the newest version
    /// is the active one, whichever of two parallel downloads lands last. A
    /// caller installing one file the user picked records it with
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
        // The download nests one image inside another: the toolkit carries
        // "Evaluation environment for Windows games <version>.dmg".
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
            // Apple's own instruction is `ditto redist/lib/ .`, so the tree is
            // kept whole rather than sorted into pieces.
            try manager.copyItem(at: lib, to: destination.appendingPathComponent("lib"))
        } catch {
            try? manager.removeItem(at: destination)
            throw InstallError.copyFailed(error.localizedDescription)
        }
        // Staging both halves is the next spawn's job (``EngineRenderers/stage``),
        // so an install that lands mid-session cannot cross this version's
        // dylib with the running tree's DLLs.
        return Installed(version: version, root: destination)
    }

    // MARK: - Reading the image

    /// `redist/lib` inside a mounted toolkit, identified by the framework
    /// rather than by a path Apple could rename.
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

    /// Waits: the images are nested, so the outer one cannot come down until
    /// the inner one has, and an unmounted image left behind is a volume in
    /// the user's Finder that this app put there.
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
            // Unconditional: what is already there can be a symlink whose
            // target does not exist yet, and `fileExists` follows symlinks.
            try? manager.removeItem(at: target)
            try manager.copyItem(at: item, to: target)
        }
    }
}
