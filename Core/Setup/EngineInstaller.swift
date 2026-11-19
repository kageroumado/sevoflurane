import Foundation

/// Downloads, verifies, and installs a managed engine release into
/// `Engines/<version>/`. Only a verified, fully extracted tree is moved into
/// place, so ``SetupProbe/managedEngineVersions()`` can treat presence as
/// installed. ``install(from:into:requiringSignature:progress:)`` installs a
/// tarball or `package-engine.sh` tree already on this Mac.
nonisolated enum EngineInstaller {
    /// The release the feed offers, or ``EngineManifest/NoRelease``.
    static func latestRelease() async throws -> EngineManifest.Release {
        try await EngineManifest.fetch().release()
    }

    static func isInstalled(_ release: EngineManifest.Release) -> Bool {
        FileManager.default.fileExists(
            atPath: Engine.managedRoot.appendingPathComponent(release.version).path,
        )
    }

    /// Download → verify → extract → atomic move; an installed version
    /// returns at once. A verified-manifest release must come from an allowed
    /// release URL and carry a valid `.sig` (``EngineSignature``) before `tar`
    /// sees a byte; every release is checked for declared size and sha256.
    @concurrent
    static func install(
        _ release: EngineManifest.Release,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws {
        guard !isInstalled(release) else { return }
        // Only a tarball already on this disk, named by an override manifest,
        // installs on its hash alone. Anything fetched is a release asset
        // with a signature, whichever manifest named it.
        let isOperatorsFile = !release.fromVerifiedManifest && release.url.isFileURL
        if !isOperatorsFile, !EngineSignature.isAllowedAssetURL(release.url) {
            throw EngineSignature.Failure.urlNotAllowed(release.url)
        }
        let manager = FileManager.default
        let staging = try makeStaging()
        defer { try? manager.removeItem(at: staging) }

        let tarball = staging.appendingPathComponent("engine.tar.xz")
        try await download(
            release, to: tarball,
            label: String(localized: "Downloading the engine (~\(release.sizeBytes / 1_000_000) MB)…"),
            progress: progress,
        )

        progress("Verifying…", nil)
        let size = try (manager.attributesOfItem(atPath: tarball.path)[.size] as? Int64) ?? -1
        guard size == release.sizeBytes else {
            throw InstallError("engine tarball is \(size) bytes, the manifest declares \(release.sizeBytes)")
        }
        let digest = try FileDigest.sha256(of: tarball)
        guard digest == release.sha256.lowercased() else {
            throw InstallError("engine tarball hash mismatch: \(digest)")
        }
        if isOperatorsFile {
            SetupLog.log("engine \(release.version) from a local override manifest: hash checked, signature skipped")
        } else {
            try await EngineSignature.verify(file: tarball, asset: release.url)
        }

        progress("Installing…", nil)
        _ = try await unpack(tarball, expecting: release.version, in: staging, into: Engine.managedRoot)
    }

    /// Installs a `dormison-r<N>.tar.xz` or a `package-engine.sh` directory
    /// from this Mac and answers its version; an installed version is never
    /// replaced. `requiringSignature` is for a file nobody chose, such as the
    /// copy beside the app; a file a person picked may go unsigned.
    @concurrent
    static func install(
        from source: URL,
        into root: URL = Engine.managedRoot,
        requiringSignature: Bool = false,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws -> String {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: source.path, isDirectory: &isDirectory) else {
            throw InstallError("no engine at \(source.path)")
        }
        if isDirectory.boolValue {
            if requiringSignature { throw EngineSignature.Failure.signatureMissing(source) }
            return try await install(fromFolder: source, into: root, progress: progress)
        }
        return try await install(
            fromTarball: source, into: root, requiringSignature: requiringSignature, progress: progress,
        )
    }

    /// Copies an engine tree named for its version through staging, so an
    /// interrupted copy never reads as installed. Never `rsync`: it maps each
    /// file it reads, which gets a process running a signed Mach-O under
    /// Rosetta killed.
    private static func install(
        fromFolder folder: URL, into root: URL,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws -> String {
        let manager = FileManager.default
        let version = folder.lastPathComponent
        guard !version.isEmpty, !version.hasPrefix(".") else {
            throw InstallError("an engine folder has to be named for its version")
        }
        guard manager.fileExists(atPath: folder.appendingPathComponent("wine/bin").path) else {
            throw InstallError("\(version) is not an engine: no wine/bin inside")
        }
        guard Engine.serverRuns(inEngineAt: folder) else {
            throw InstallError(Engine.intelRefusal(version))
        }
        let destination = root.appendingPathComponent(version)
        guard !manager.fileExists(atPath: destination.path) else {
            throw InstallError("engine \(version) is already installed")
        }
        progress(String(localized: "Copying \(version)…"), nil)
        let staging = try makeStaging()
        defer { try? manager.removeItem(at: staging) }
        let tree = staging.appendingPathComponent(version)
        let copy = await Subprocess.run(
            "/bin/cp", ["-Rp", folder.path, tree.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard copy.status == 0 else {
            throw InstallError("engine copy failed: \(copy.output.suffix(200))")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.moveItem(at: tree, to: destination)
        SetupLog.log("engine folder \(folder.path): installed as \(version)")
        return version
    }

    /// Verifies a `<name>.sig` beside the tarball when there is one; an
    /// unsigned tarball installs unless a signature is required.
    private static func install(
        fromTarball tarball: URL, into root: URL, requiringSignature: Bool,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws -> String {
        let manager = FileManager.default
        let named = versionName(of: tarball)
        guard !manager.fileExists(atPath: root.appendingPathComponent(named).path) else {
            throw InstallError("engine \(named) is already installed")
        }
        progress(String(localized: "Verifying \(tarball.lastPathComponent)…"), nil)
        let signatureURL = EngineSignature.signatureURL(for: tarball)
        var isSigned = false
        if let signatureFile = try? Data(contentsOf: signatureURL) {
            try EngineSignature.verify(file: tarball, signatureFile: signatureFile)
            SetupLog.log("engine tarball \(tarball.lastPathComponent): signature verified")
            isSigned = true
        } else if requiringSignature {
            throw EngineSignature.Failure.signatureMissing(signatureURL)
        } else {
            SetupLog.log("engine tarball \(tarball.lastPathComponent): no .sig beside it, installed as the operator's own")
        }
        progress("Installing…", nil)
        let staging = try makeStaging()
        defer { try? manager.removeItem(at: staging) }
        // A signature covers the bytes, never the file's name: a signed
        // tarball must hold the engine it is named for, or an old release
        // renamed to a newer number would install as the upgrade it claims.
        return try await unpack(tarball, expecting: isSigned ? named : nil, in: staging, into: root)
    }

    /// The engine a tarball is named for: `dormison-b1.tar.xz` → `dormison-b1`.
    static func versionName(of tarball: URL) -> String {
        var name = tarball.lastPathComponent
        for suffix in [".tar.xz", ".txz", ".tar"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    /// The newest engine tarball in `Contents/Resources/Engine/` or beside
    /// the app bundle (a disk image's root). Only one with a `.sig` counts:
    /// the folder beside the app is often Downloads, where any file lands.
    static func bundledTarball(
        resources: URL? = Bundle.main.resourceURL,
        beside bundle: URL = Bundle.main.bundleURL,
    ) -> URL? {
        let manager = FileManager.default
        let places = [resources?.appendingPathComponent("Engine"), bundle.deletingLastPathComponent()]
            .compactMap(\.self)
        let candidates = places.flatMap { place in
            ((try? manager.contentsOfDirectory(atPath: place.path)) ?? [])
                .filter { $0.hasPrefix("dormison-") && $0.hasSuffix(".tar.xz") }
                .map(place.appendingPathComponent)
                .filter { manager.fileExists(atPath: EngineSignature.signatureURL(for: $0).path) }
        }
        return candidates.max { Engine.isOlderVersion(versionName(of: $0), than: versionName(of: $1)) }
    }

    /// The bundled engine when it is newer than every installed one; `nil`
    /// before setup, which installs it itself.
    static func bundledUpgrade(bundled: URL? = bundledTarball(), installed: [String]) -> URL? {
        guard let bundled, let newest = installed.max(by: Engine.isOlderVersion) else { return nil }
        let version = versionName(of: bundled)
        guard !installed.contains(version), Engine.isOlderVersion(newest, than: version) else { return nil }
        return bundled
    }

    private static func makeStaging() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Extracts `tarball` and moves its single top-level directory, named for
    /// the version (`expected` when given), into `root`. The tree must carry
    /// `wine/bin`, what ``Engine/existsOnDisk`` looks for.
    private static func unpack(
        _ tarball: URL, expecting expected: String?, in staging: URL, into root: URL,
    ) async throws -> String {
        let manager = FileManager.default
        let extracted = staging.appendingPathComponent("extracted")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        // Through a pipe: tar reading the file copies the archive's quarantine
        // onto every file, and a quarantined ad-hoc signed binary never execs.
        let untar = await Subprocess.run(
            "/bin/sh", ["-c", #"/bin/cat -- "$0" | /usr/bin/tar -xf - -C "$1""#, tarball.path, extracted.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard untar.status == 0 else {
            throw InstallError("engine extraction failed: \(untar.output.suffix(200))")
        }
        try await clearQuarantine(under: extracted)

        let contents = try manager.contentsOfDirectory(atPath: extracted.path)
            .filter { !$0.hasPrefix(".") }
        guard contents.count == 1, let version = contents.first,
              expected == nil || version == expected
        else {
            throw InstallError("engine tarball layout unexpected: \(contents)")
        }
        let tree = extracted.appendingPathComponent(version)
        guard manager.fileExists(atPath: tree.appendingPathComponent("wine/bin").path) else {
            throw InstallError("\(version) is not an engine: no wine/bin inside")
        }
        guard Engine.serverRuns(inEngineAt: tree) else {
            throw InstallError(Engine.intelRefusal(version))
        }
        let destination = root.appendingPathComponent(version)
        guard !manager.fileExists(atPath: destination.path) else {
            throw InstallError("engine \(version) is already installed")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.moveItem(at: tree, to: destination)
        return version
    }

    /// Makes the tree owner-writable and unquarantined. Must run before
    /// anything in it executes: Gatekeeper keeps its first verdict.
    static func clearQuarantine(under root: URL) async throws {
        _ = await Subprocess.run("/bin/chmod", ["-R", "u+w", root.path])
        let stuck = removeQuarantine(under: root)
        guard stuck.isEmpty else {
            throw InstallError("engine files still quarantined: \(stuck.prefix(3).joined(separator: ", "))")
        }
    }

    /// Strips quarantine under `root`, answering the files it stayed on.
    private static func removeQuarantine(under root: URL) -> [String] {
        guard let walk = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var stuck: [String] = []
        for case let relative as String in walk {
            let path = root.appendingPathComponent(relative).path
            guard getxattr(path, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 else { continue }
            if removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 { stuck.append(relative) }
        }
        return stuck
    }

    private static let quarantineAttribute = "com.apple.quarantine"

    /// Downloads the tarball through an observed download task. Never an
    /// `AsyncBytes` loop: an await per byte turns seconds into minutes. The
    /// temp file must be moved inside the completion handler, which deletes
    /// it on return. Cancellation cancels the transfer; a non-2xx status fails.
    static func download(
        _ release: EngineManifest.Release, to tarball: URL,
        label: String, session: URLSession = .shared,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws {
        progress(label, 0)
        let declaredBytes = release.sizeBytes
        let transfer = Transfer()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let task = session.downloadTask(with: release.url) { temp, response, error in
                    transfer.finish()
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
                        continuation.resume(throwing: InstallError(
                            "engine download failed: HTTP \(http.statusCode) from \(release.url.absoluteString)",
                        ))
                        return
                    }
                    guard let temp else {
                        continuation.resume(throwing: InstallError("engine download produced no file"))
                        return
                    }
                    do {
                        try FileManager.default.moveItem(at: temp, to: tarball)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
                nonisolated(unsafe) var lastReported = 0.0
                let observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                    // Without a response length, the declared size stands in.
                    let fraction = taskProgress.totalUnitCount > 0
                        ? taskProgress.fractionCompleted
                        : Double(taskProgress.completedUnitCount) / Double(declaredBytes)
                    guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
                    lastReported = fraction
                    progress(label, min(1, fraction))
                }
                transfer.start(task, observing: observation)
            }
        } onCancel: {
            transfer.cancel()
        }
    }

    /// One download's task and observation. A cancel before the task exists
    /// is remembered and applied when it starts.
    private final class Transfer: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionDownloadTask?
        private var observation: NSKeyValueObservation?
        private var isCancelled = false

        func start(_ task: URLSessionDownloadTask, observing observation: NSKeyValueObservation) {
            let cancelled = lock.withLock {
                self.task = task
                self.observation = observation
                return isCancelled
            }
            task.resume()
            if cancelled { task.cancel() }
        }

        func cancel() {
            let task = lock.withLock {
                isCancelled = true
                return self.task
            }
            task?.cancel()
        }

        func finish() {
            let observation = lock.withLock {
                defer { self.observation = nil }
                return self.observation
            }
            observation?.invalidate()
        }
    }

    private struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
