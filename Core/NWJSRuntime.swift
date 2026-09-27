import Foundation

/// The macOS NW.js builds a native run needs, one directory per version under
/// `Runtimes/`. NW.js publishes every release it ever made, so a game can have
/// the Chromium and node its own code was written against.
///
/// It gets them only when this Mac can run that release without translation.
/// A game from 2018 asks for NW.js 0.29, whose macOS build is x86_64: under
/// Rosetta, Chromium 65's stack sampling profiler walks a translated frame
/// with libunwind and takes the browser process down with it — measured on
/// macOS 26, a crash report per launch, four launches in five. NW.js has
/// published arm64 builds since 0.77, and on an Apple Silicon Mac that is
/// where an old game goes instead: a five-year jump in Chromium, against a
/// runtime that cannot run at all.
nonisolated enum NWJSRuntime {
    static let root = UserHome.url
        .appendingPathComponent("Library/Application Support/Sevoflurane/Runtimes")

    /// The version directory, whether or not it exists.
    static func directory(version: String) -> URL {
        root.appendingPathComponent("nwjs-v\(version)")
    }

    /// The binary a game is exec'd into.
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

    /// The installed runtime a game runs on: the release the switch recorded
    /// for it, or — for a game switched on before that was recorded — the
    /// newest installed patch of the game's own series. `nil` when nothing
    /// suitable is installed: a game whose runner is set and whose runtime is
    /// gone is a state to report, not one to paper over with a mismatched
    /// Chromium.
    static func installedRuntime(recorded: String?, gameVersion: String) -> URL? {
        if let recorded, isInstalled(version: recorded) {
            return executable(version: recorded)
        }
        guard let wanted = series(of: gameVersion),
              let match = installed().last(where: { series(of: $0) == wanted })
        else { return nil }
        return executable(version: match)
    }

    /// "0.29.0" → "0.29". The series is what decides compatibility: NW.js
    /// changes Chromium and node between minors, never within one.
    static func series(of version: String) -> String? {
        let parts = version.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        return "\(parts[0]).\(parts[1])"
    }

    // MARK: - Choosing a version

    /// The release a game should run on: the newest patch of its own series
    /// when that series ships a build for this Mac's architecture, and
    /// otherwise the oldest release that does — the closest native runtime to
    /// the one the game was written against.
    ///
    /// Falls back to the game's exact version when NW.js' index cannot be
    /// reached, which is also when nothing could be downloaded anyway.
    static func release(forGameVersion version: String) async -> String {
        guard let url = URL(string: "https://nwjs.io/versions.json"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let chosen = release(
                  forGameVersion: version, in: index(from: data), flavor: nativeFlavor,
              )
        else { return version }
        return chosen
    }

    /// One release as NW.js' published index names it: the version, and the
    /// build flavors that release shipped.
    struct IndexEntry: Sendable, Equatable {
        let version: String
        let flavors: [String]
    }

    /// `versions.json` reduced to the releases a game could be sent to.
    /// Prereleases are dropped: a version carrying a suffix ("0.29.0-beta1")
    /// is never what a shipped game was built against.
    static func index(from data: Data) -> [IndexEntry] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = object["versions"] as? [[String: Any]]
        else { return [] }
        return entries.compactMap { entry in
            guard let raw = entry["version"] as? String else { return nil }
            let number = raw.hasPrefix("v") ? String(raw.dropFirst()) : raw
            guard !number.contains("-") else { return nil }
            return IndexEntry(version: number, flavors: entry["files"] as? [String] ?? [])
        }
    }

    /// The release out of `index` a game should run on: the newest patch of
    /// its own series when that series ships `flavor`, and otherwise the
    /// oldest release that does — which on an Apple Silicon Mac is 0.77, the
    /// first NW.js with an arm64 build. `nil` when the version names no series
    /// or the index names no build of this flavor, and the caller then has
    /// nothing better than the game's own version.
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

    /// The build flavor this Mac runs without translation. Rosetta would run
    /// the x64 one, and running an old Chromium there is what this exists to
    /// avoid.
    static var nativeFlavor: String {
        var isARM: Int32 = 0
        var size = MemoryLayout<Int32>.size
        let native = sysctlbyname("hw.optional.arm64", &isARM, &size, nil, 0) == 0 && isARM == 1
        return native ? "osx-arm64" : "osx-x64"
    }

    // MARK: - Installing

    /// The runtime for `version`, downloading and unpacking it when it is not
    /// already on disk. Answers the executable to exec.
    static func ensure(
        version: String,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws -> URL {
        let binary = executable(version: version)
        if isInstalled(version: version) { return binary }
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

        progress("Unpacking NW.js \(version)…", nil)
        let unpacked = staging.appendingPathComponent("unpacked")
        // ditto, not unzip: the app bundle is full of symlinks into its own
        // Versions directory, and a copy that flattens them will not launch.
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

        // Gatekeeper judges by the quarantine flag, which the download carries
        // and the notarized binary inside does not need.
        _ = await Subprocess.run(
            "/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path],
            capture: .combined, timeout: .seconds(120),
        )

        let destination = directory(version: version)
        try? manager.removeItem(at: destination)
        try manager.createDirectory(at: destination, withIntermediateDirectories: true)
        try manager.moveItem(at: app, to: destination.appendingPathComponent("nwjs.app"))
        guard isInstalled(version: version) else {
            throw RuntimeError("the NW.js \(version) tree has no runnable binary")
        }
        return binary
    }

    /// Adds a runtime from a folder already on this Mac — the unpacked
    /// `nwjs-v<version>-<flavor>` directory NW.js publishes, or the
    /// `nwjs.app` inside one. The route for a Mac that cannot reach
    /// `dl.nwjs.io`, and for a build someone made themselves.
    ///
    /// `ditto`, because the bundle is full of symlinks into its own
    /// `Versions` directory and a copy that flattens them will not launch.
    @discardableResult
    static func install(fromFolder folder: URL, version: String? = nil) async throws -> String {
        let manager = FileManager.default
        let app = folder.lastPathComponent == "nwjs.app" ? folder : findApp(under: folder)
        guard let app else {
            throw RuntimeError("no nwjs.app inside \(folder.lastPathComponent)")
        }
        guard let number = version ?? versionName(ofFolder: folder) else {
            throw RuntimeError(
                "could not tell the NW.js version from \(folder.lastPathComponent); pass one",
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

    /// `nwjs-v0.77.0-osx-arm64` → `0.77.0`. A bundle's own Info.plist is no
    /// help here: it carries Chromium's version, not NW.js'.
    static func versionName(ofFolder folder: URL) -> String? {
        let name = folder.lastPathComponent
        guard name.hasPrefix("nwjs-v") else { return nil }
        let number = name.dropFirst("nwjs-v".count).prefix { $0.isNumber || $0 == "." }
        return number.isEmpty ? nil : String(number)
    }

    /// The archive nests the bundle one directory down
    /// (`nwjs-v0.29.4-osx-x64/nwjs.app`), and has changed shape between
    /// releases, so the bundle is found rather than assumed.
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

    /// A plain download task whose `Progress` is observed — the shape
    /// ``EngineInstaller`` settled on. The temporary file has to be moved
    /// inside the completion handler: URLSession deletes it when the handler
    /// returns.
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
            let task = URLSession.shared.downloadTask(with: url) { temp, _, error in
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
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
