import AppKit
import CryptoKit
import Foundation
import Security

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

    enum InstallError: Error, CustomStringConvertible, Equatable {
        case notAToolkit(String)
        case attachFailed(String)
        case copyFailed(String)
        /// A file that is not Apple's: unsigned or re-signed native code, a
        /// link that leaves the image, or a Windows DLL unlike the version's.
        case notApples(String)
        /// A version found in a watched folder that this build has no record
        /// of, so nothing vouches for its Windows half.
        case unknownVersionFound(String)

        var description: String {
            switch self {
            case let .notAToolkit(path):
                "\(path) does not contain Apple's evaluation environment "
                    + "(no redist/lib/external/D3DMetal.framework inside)"
            case let .attachFailed(detail): "could not open the disk image: \(detail)"
            case let .copyFailed(detail): "could not install D3DMetal: \(detail)"
            case let .notApples(file):
                "\(file) in this disk image is not Apple's. Download the toolkit from developer.apple.com again."
            case let .unknownVersionFound(version):
                "Version \(version) is new to Sevoflurane, so it was not installed on its own. "
                    + "If you downloaded it from Apple, add it with Choose the File."
            }
        }
    }

    /// How a toolkit reached the installer.
    enum Origin: Sendable {
        /// The user picked this file, or the app downloaded it from Apple.
        case chosen
        /// A watched folder turned it up. Any site can put a file with the
        /// right name in Downloads, so only a version whose Windows DLLs are
        /// on record installs this way.
        case foundInFolder
    }

    /// The Windows programs of the versions on record, by their path under
    /// `redist/lib` and SHA-256. macOS checks the image's native code against
    /// Apple's signature; nothing but this table speaks for a PE file, so a
    /// version on record holds exactly these and no other, anywhere.
    static let knownWindowsHalves: [String: [String: String]] = [
        "3.0": [
            "wine/x86_64-windows/atidxx64.dll": "bd004dd9e41415b0e1395d51a2ded762a02c7731491e74ed6076f3648ae9ea7f",
            "wine/x86_64-windows/d3d10.dll": "d316848cc78301829e6031b60c6f558716cdc74c440df72935968160253c03a5",
            "wine/x86_64-windows/d3d11.dll": "05fa6f700fb5ee5561dc3a46d98f0aed845d4fa8ab274bff1dc604b0b3f6edd1",
            "wine/x86_64-windows/d3d12.dll": "27dcf69bedb20ed557a83953e356ab2477b688c2a2c631f880b7583f30ff0705",
            "wine/x86_64-windows/dxgi.dll": "249711d3d786a9b0bb7c3558f36e472ab07ee21b8dbf118e34c975046832f9a2",
            "wine/x86_64-windows/nvapi64.dll": "8e1e6cde85551360d7a061a09445500f3c38805651502f3be65049d937c6960c",
            "wine/x86_64-windows/nvngx-on-metalfx.dll": "d7c0df74d9bb4de5e2a3cc357b2309148fd3fdc824fe7941e4d789dbd072ff99",
        ],
        "4.0 beta 2": [
            "wine/x86_64-windows/d3d10.dll": "14c84a364a1260497f0a5117ef8efd6e228764ab139a67af1127e8bd013c48c7",
            "wine/x86_64-windows/d3d11.dll": "303b2bb41efa30c890e2e93d39c3d3c565c8557e069eee832f2cb8a37bd4ec26",
            "wine/x86_64-windows/d3d12.dll": "1b7a02cb37ec6b484e2aaa76b5ec9cbb47e63aeec29dbe087d5d1589a3347cfb",
            "wine/x86_64-windows/dxgi.dll": "522a8b37216afb09e614489d88a74118076f4d7e08d2b289df6a6eb6f3e817af",
            "wine/x86_64-windows/nvapi64.dll": "05eedf19e75c6b4c0dce918577aa6ca3fe5da79d04e42145cf66f498fad3556a",
            "wine/x86_64-windows/nvngx-on-metalfx.dll": "f6bc9d77fd1e898fec8c6339d367bd8e0f338992c9c0c66d59b30c6e9e0743e4",
        ],
    ]

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
    ///
    /// Nothing is copied before `vet` passes the image's `redist/lib`: these
    /// files become code the engine loads.
    @concurrent
    static func install(
        from source: URL, intoEngine engine: URL, origin: Origin = .chosen,
        vet: @Sendable (URL, String, Origin) throws -> Void = { try D3DMetalInstaller.vet(lib: $0, version: $1, origin: $2) },
    ) async throws -> Installed {
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

        guard let version = version(ofVolume: searchRoot) else {
            throw InstallError.notAToolkit(source.path)
        }
        try vet(lib, version, origin)
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
    /// environment for Windows games 4.0 beta 2". Nil for any other name: the
    /// version becomes a folder name, and the volume's author chose it.
    static func version(ofVolume volume: URL) -> String? {
        let name = volume.lastPathComponent
        guard let range = name.range(
            of: #"[0-9]+\.[0-9]+( beta [0-9]+)?"#, options: .regularExpression,
        ) else { return nil }
        return String(name[range])
    }

    // MARK: - Vetting

    /// Throws unless everything executable under a toolkit's `redist/lib` is
    /// Apple's: native code carries Apple's own signature, every link stays
    /// inside the folder, and the Windows DLLs are the version's on record.
    /// A version with no record passes on its native half alone when the user
    /// chose the file, and not at all when a folder watch found it.
    static func vet(
        lib: URL, version: String, origin: Origin, records: [String: [String: String]] = knownWindowsHalves,
    ) throws {
        let root = lib.resolvingSymlinksInPath().path
        // Keyed by path: a second file of the same name in another folder is
        // another file, and the one that is staged is the one that is judged.
        var windows: [String: String] = [:]
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey]
        guard let walk = FileManager.default.enumerator(at: lib, includingPropertiesForKeys: keys) else {
            throw InstallError.notAToolkit(lib.path)
        }
        for case let item as URL in walk {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                guard item.resolvingSymlinksInPath().path.hasPrefix(root + "/") else {
                    throw InstallError.notApples(item.lastPathComponent)
                }
                continue
            }
            if item.pathExtension == "framework" {
                try requireAppleSignature(item)
                walk.skipDescendants()
            } else if values?.isRegularFile == true {
                switch executableKind(of: item) {
                case .machO: try requireAppleSignature(item)
                case .windows:
                    let path = item.resolvingSymlinksInPath().path
                    guard path.hasPrefix(root + "/") else { throw InstallError.notApples(item.lastPathComponent) }
                    windows[String(path.dropFirst(root.count + 1))] = try FileDigest.sha256(of: item)
                case nil: break
                }
            }
        }
        if let known = records[version] {
            guard windows == known else {
                let odd = Set(windows.keys).symmetricDifference(known.keys).sorted().first
                    ?? windows.first { known[$0.key] != $0.value }?.key ?? "a Windows DLL"
                throw InstallError.notApples(odd)
            }
        } else if origin == .foundInFolder {
            throw InstallError.unknownVersionFound(version)
        }
    }

    private enum ExecutableKind { case machO, windows }

    /// Judged by the file's first bytes, never its name.
    private static func executableKind(of file: URL) -> ExecutableKind? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let head = [UInt8]((try? handle.read(upToCount: 4)) ?? Data())
        guard head.count == 4 else { return nil }
        if head[0] == 0x4D, head[1] == 0x5A { return .windows }
        let magic = UInt32(head[0]) << 24 | UInt32(head[1]) << 16 | UInt32(head[2]) << 8 | UInt32(head[3])
        // Thin, fat and their byte-swapped forms.
        return [0xFEED_FACE, 0xFEED_FACF, 0xCEFA_EDFE, 0xCFFA_EDFE, 0xCAFE_BABE, 0xBEBA_FECA].contains(magic)
            ? .machO : nil
    }

    /// `anchor apple`: signed by Apple as its own software, which a Developer
    /// ID or an ad hoc signature never satisfies.
    private static func requireAppleSignature(_ subject: URL) throws {
        var requirement: SecRequirement?
        var code: SecStaticCode?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecRequirementCreateWithString("anchor apple" as CFString, [], &requirement) == errSecSuccess,
              SecStaticCodeCreateWithPath(subject as CFURL, [], &code) == errSecSuccess,
              let requirement, let code,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess
        else { throw InstallError.notApples(subject.lastPathComponent) }
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
