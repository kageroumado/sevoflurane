import Foundation

/// The macOS NW.js builds native runs use, one directory per version under `Runtimes/`.
///
/// Only builds this Mac runs without translation are used: under Rosetta, the x86_64 NW.js 0.29 a
/// 2018 game asks for crashes in Chromium 65's stack sampling profiler, which walks a translated
/// frame with libunwind (measured on macOS 26: four launches in five). arm64 builds start at 0.77,
/// so on Apple Silicon an old game takes a five-year jump in Chromium instead.
nonisolated enum NWJSRuntime {
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Runtimes")

    static func directory(version: String) -> URL {
        root.appendingPathComponent("nwjs-v\(version)")
    }

    static func executable(version: String) -> URL {
        directory(version: version).appendingPathComponent("nwjs.app/Contents/MacOS/nwjs")
    }

    static func isInstalled(version: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: executable(version: version).path)
    }

    /// Every runtime on disk, oldest first.
    static func installed() -> [String] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
        )) ?? []
        return entries
            .map(\.lastPathComponent)
            .filter { $0.hasPrefix("nwjs-v") }
            .map { String($0.dropFirst("nwjs-v".count)) }
            .filter(isInstalled(version:))
            .sorted { $0.compare($1, options: .numeric) == .orderedAscending }
    }

    /// The installed runtime a game runs on: the release recorded at its switch, else the newest
    /// installed native patch of its series. `nil` when nothing suitable is installed; never fall
    /// back to a mismatched Chromium or an x86_64 build under Rosetta.
    static func installedRuntime(recorded: String?, gameVersion: String) -> URL? {
        if let recorded, isInstalled(version: recorded) {
            return executable(version: recorded)
        }
        guard let wanted = series(of: gameVersion),
              let match = installed().last(where: {
                  series(of: $0) == wanted && runsNatively(executable(version: $0))
              })
        else { return nil }
        return executable(version: match)
    }

    /// Whether a Mach-O binary has a slice for this Mac's architecture: a thin binary's CPU type,
    /// or any fat-table entry.
    static func runsNatively(_ binary: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return false }
        let wanted: UInt32 = nativeFlavor == "osx-arm64" ? 0x0100_000C : 0x0100_0007
        func word(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset + 4 <= header.count else { return nil }
            let bytes = header[header.startIndex + offset ..< header.startIndex + offset + 4]
            let value = bytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            return bigEndian ? value : value.byteSwapped
        }
        switch word(0, bigEndian: true) {
        case 0xCFFA_EDFE:
            // MH_MAGIC_64 as little-endian bytes; cputype follows it.
            return word(4, bigEndian: false) == wanted
        case 0xCAFE_BABE:
            // FAT_MAGIC, big-endian: a count, then 20-byte entries led by cputype.
            let count = Int(word(4, bigEndian: true) ?? 0)
            return (0 ..< count).contains { word(8 + $0 * 20, bigEndian: true) == wanted }
        default:
            return false
        }
    }

    /// "0.29.0" → "0.29". NW.js changes Chromium and node between minors, never within one, so the
    /// series decides compatibility.
    static func series(of version: String) -> String? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    // MARK: - Choosing a version

    /// The release a game should run on (see ``release(forGameVersion:in:flavor:)``), from the
    /// releases ``NWJSPins`` can verify; nil when the game's version names no series.
    static func release(forGameVersion version: String) -> String? {
        release(forGameVersion: version, in: NWJSPins.index, flavor: nativeFlavor)
    }

    /// One release, with the build flavors it shipped.
    struct IndexEntry: Sendable, Equatable {
        let version: String
        let flavors: [String]
    }

    /// Whether `version` is three dot-separated numbers. A game's loader states its version, and
    /// the string becomes a folder name and part of a URL.
    static func isReleaseNumber(_ version: String) -> Bool {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 3 && parts.allSatisfy { !$0.isEmpty && $0.count <= 4 && $0.allSatisfy { ("0" ... "9").contains($0) } }
    }

    /// The newest patch of the game's series that ships `flavor`, else the oldest release that does
    /// (0.77 for arm64). `nil` when the version has no series or no release ships `flavor`.
    static func release(
        forGameVersion version: String, in index: [IndexEntry], flavor: String,
    ) -> String? {
        guard let wanted = series(of: version) else { return nil }
        let native = index.filter { $0.flavors.contains(flavor) }.map(\.version)
        let ascending = { (first: String, second: String) in
            first.compare(second, options: .numeric) == .orderedAscending
        }
        if let own = native.filter({ series(of: $0) == wanted }).max(by: ascending) {
            return own
        }
        return native.min(by: ascending)
    }

    /// The build flavor this Mac runs without translation.
    static var nativeFlavor: String {
        var isARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let native = sysctlbyname("hw.optional.arm64", &isARM, &size, nil, 0) == 0 && isARM == 1
        return native ? "osx-arm64" : "osx-x64"
    }

    // MARK: - Installing

    /// The runtime for `version`, downloaded and unpacked when missing; answers the executable.
    /// A second call for a version being installed waits for that install.
    static func ensure(
        version: String,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws -> URL {
        guard isReleaseNumber(version) else { throw RuntimeError("\(version) is not an NW.js release number") }
        if isInstalled(version: version) { return executable(version: version) }
        return try await installs.run(version) { try await fetchAndInstall(version: version, progress: progress) }
    }

    /// The installs under way in this process, one per version.
    private static let installs = InstallsInFlight()

    private actor InstallsInFlight {
        private var running: [String: Task<URL, any Error>] = [:]

        func run(_ version: String, _ work: @escaping @Sendable () async throws -> URL) async throws -> URL {
            if let task = running[version] { return try await task.value }
            let task = Task { try await work() }
            running[version] = task
            defer { running[version] = nil }
            return try await task.value
        }
    }

    private static func fetchAndInstall(
        version: String, progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws -> URL {
        let binary = executable(version: version)
        if isInstalled(version: version) { return binary }
        guard let digest = NWJSPins.archives[version]?[nativeFlavor] else {
            throw RuntimeError(
                "NW.js \(version) is not a release this version of Sevoflurane can verify; "
                    + "add it from a folder with sevo nwjs add",
            )
        }
        guard let url = URL(
            string: "https://dl.nwjs.io/v\(version)/nwjs-v\(version)-\(nativeFlavor).zip",
        ) else { throw RuntimeError("nwjs \(version) has no download address") }

        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-nwjs-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        let archive = staging.appendingPathComponent("nwjs.zip")
        try await download(url, to: archive, label: "Downloading NW.js \(version)…", progress: progress)
        // NW.js is unsigned and runs outside Wine, as this account.
        guard try FileDigest.sha256(of: archive) == digest else {
            throw RuntimeError("the NW.js \(version) download is not the published release; nothing was installed")
        }

        progress("Unpacking NW.js \(version)…", nil)
        let unpacked = staging.appendingPathComponent("unpacked")
        // Never unzip: the bundle's symlinks into its `Versions` directory must survive, or it will
        // not launch.
        let extraction = await Subprocess.run(
            "/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard extraction.status == 0 else {
            throw RuntimeError("could not unpack NW.js: \(extraction.output.suffix(200))")
        }
        guard let app = findApp(under: unpacked) else {
            throw RuntimeError("the NW.js \(version) archive holds no nwjs.app")
        }

        // The build is unsigned, so Gatekeeper would refuse it under quarantine; the digest above
        // is what vouches for it.
        _ = await Subprocess.run(
            "/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path],
            capture: .combined, timeout: .seconds(120),
        )

        // The app and `sevo` can both install one version; the one that
        // places it first wins, and the other keeps that copy.
        return try withPlacementLock {
            if isInstalled(version: version) { return binary }
            let destination = directory(version: version)
            try? manager.removeItem(at: destination)
            try manager.createDirectory(at: destination, withIntermediateDirectories: true)
            try manager.moveItem(at: app, to: destination.appendingPathComponent("nwjs.app"))
            guard isInstalled(version: version) else {
                throw RuntimeError("the NW.js \(version) tree has no runnable binary")
            }
            return binary
        }
    }

    /// Runs `body` holding an advisory lock beside the runtimes, which every
    /// process that places one takes.
    private static func withPlacementLock<T>(_ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(root.appendingPathComponent(".install.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return try body() }
        defer { close(descriptor) }
        flock(descriptor, LOCK_EX)
        defer { flock(descriptor, LOCK_UN) }
        return try body()
    }

    /// Adds a runtime from a local folder: the unpacked `nwjs-v<version>-<flavor>` directory or its
    /// `nwjs.app`, for a Mac that cannot reach `dl.nwjs.io` or a self-made build. Copied with
    /// `ditto` to keep the bundle's symlinks.
    @discardableResult
    static func install(fromFolder folder: URL, version: String? = nil) async throws -> String {
        let manager = FileManager.default
        let app = folder.lastPathComponent == "nwjs.app" ? folder : findApp(under: folder)
        guard let app else {
            throw RuntimeError("no nwjs.app inside \(folder.lastPathComponent)")
        }
        guard let number = version ?? versionName(ofFolder: folder), isReleaseNumber(number) else {
            throw RuntimeError(
                "could not tell the NW.js version from \(folder.lastPathComponent); pass one, as in 0.77.0",
            )
        }
        guard !isInstalled(version: number) else {
            throw RuntimeError("NW.js \(number) is already installed")
        }
        let destination = directory(version: number)
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        let copy = await Subprocess.run(
            "/usr/bin/ditto", [app.path, destination.appendingPathComponent("nwjs.app").path],
            capture: .combined, timeout: .seconds(600),
        )
        guard copy.status == 0 else {
            throw RuntimeError("could not copy the runtime: \(copy.output.suffix(200))")
        }
        guard isInstalled(version: number) else {
            try? manager.removeItem(at: destination)
            throw RuntimeError("\(folder.lastPathComponent) holds no runnable NW.js binary")
        }
        return number
    }

    /// `nwjs-v0.77.0-osx-arm64` → `0.77.0`. The bundle's Info.plist carries Chromium's version, not
    /// NW.js'.
    static func versionName(ofFolder folder: URL) -> String? {
        let name = folder.lastPathComponent
        guard name.hasPrefix("nwjs-v") else { return nil }
        let number = name.dropFirst("nwjs-v".count).prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? nil : String(number)
    }

    /// Finds `nwjs.app` up to three levels down; archives nest it differently across releases.
    private static func findApp(under root: URL) -> URL? {
        let manager = FileManager.default
        var frontier = [root]
        for _ in 0 ..< 3 {
            var next: [URL] = []
            for directory in frontier {
                let entries = (try? manager.contentsOfDirectory(
                    at: directory, includingPropertiesForKeys: [.isDirectoryKey],
                )) ?? []
                for entry in entries {
                    if entry.lastPathComponent == "nwjs.app" { return entry }
                    if (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?
                        .isDirectory == true { next.append(entry) }
                }
            }
            frontier = next
        }
        return nil
    }

    /// Downloads with progress, as ``EngineInstaller`` does. The temporary file must be moved
    /// inside the completion handler, which deletes it on return.
    private static func download(
        _ url: URL, to file: URL,
        label: String, progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws {
        progress(label, 0)
        final class ObservationBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
        }
        let box = ObservationBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task = URLSession.shared.downloadTask(with: url) { temp, response, error in
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                // A missing build answers 404 with a page that would otherwise reach the unzip
                // step.
                if let status = (response as? HTTPURLResponse)?.statusCode, status != 200 {
                    continuation.resume(throwing: RuntimeError(
                        "\(url.lastPathComponent) is not published (HTTP \(status))",
                    ))
                    return
                }
                guard let temp else {
                    continuation.resume(throwing: RuntimeError("the NW.js download produced no file"))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: temp, to: file)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            nonisolated(unsafe) var lastReported = 0.0
            box.observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                let fraction = taskProgress.fractionCompleted
                guard fraction - lastReported >= 0.05 || fraction >= 1 else { return }
                lastReported = fraction
                progress(label, min(1, fraction))
            }
            task.resume()
        }
    }

    struct RuntimeError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
