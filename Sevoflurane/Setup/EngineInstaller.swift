import CryptoKit
import Foundation

/// Downloads, verifies, and installs a managed engine release into
/// `Engines/<version>/`. The download lands in a
/// temporary directory and only an integrity-verified, fully extracted tree
/// is moved into place — a version directory either exists complete or not
/// at all, which is what lets ``SetupProbe/managedEngineVersions()`` treat
/// presence as installed.
///
/// An engine can also come from this Mac, ``install(from:into:progress:)``:
/// the release asset someone saved by hand on a Mac the release feed does
/// not reach, the copy a disk image ships with the app
/// (``bundledTarball(resources:beside:)``), or the tree `package-engine.sh`
/// left behind for whoever built it.
nonisolated enum EngineInstaller {
    /// Fetches the release this Mac's channel names, or reports why the
    /// machine can't use it.
    static func stableRelease() async throws -> EngineManifest.Release {
        guard let release = try await EngineManifest.fetch().release() else {
            throw InstallError("engine manifest has no stable channel")
        }
        return release
    }

    static func isInstalled(_ release: EngineManifest.Release) -> Bool {
        FileManager.default.fileExists(
            atPath: Engine.managedRoot.appendingPathComponent(release.version).path,
        )
    }

    /// Download → verify → extract → atomic move into place.
    /// Idempotent: an already-installed version returns immediately. The
    /// fraction is the download's progress against the manifest's declared
    /// size, or `nil` for the phases with no measurable whole.
    ///
    /// A release from the verified manifest is held to the whole policy
    /// (``EngineSignature``): the tarball comes from a kageroumado release
    /// asset over HTTPS, is exactly the declared size, hashes to the declared
    /// sha256, and its `.sig` verifies against the pinned key — all before
    /// `tar` sees a byte. A release from an override manifest is checked by
    /// size and hash.
    @concurrent
    static func install(
        _ release: EngineManifest.Release,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws {
        guard !isInstalled(release) else { return }
        if release.fromVerifiedManifest, !EngineSignature.isAllowedAssetURL(release.url) {
            throw EngineSignature.Failure.urlNotAllowed(release.url)
        }
        let manager = FileManager.default
        let staging = try makeStaging()
        defer { try? manager.removeItem(at: staging) }

        let tarball = staging.appendingPathComponent("engine.tar.xz")
        try await download(
            release, to: tarball,
            label: "Downloading the engine (~\(release.sizeBytes / 1_000_000) MB)…",
            progress: progress,
        )

        progress("Verifying…", nil)
        let size = try (manager.attributesOfItem(atPath: tarball.path)[.size] as? Int64) ?? -1
        guard size == release.sizeBytes else {
            throw InstallError("engine tarball is \(size) bytes, the manifest declares \(release.sizeBytes)")
        }
        let digest = try sha256(of: tarball)
        guard digest == release.sha256.lowercased() else {
            throw InstallError("engine tarball hash mismatch: \(digest)")
        }
        if release.fromVerifiedManifest {
            try await EngineSignature.verify(file: tarball, asset: release.url)
        } else {
            SetupLog.log("engine \(release.version) from an override manifest: hash checked, signature skipped")
        }

        progress("Installing…", nil)
        _ = try await unpack(tarball, expecting: release.version, in: staging, into: Engine.managedRoot)
    }

    /// Installs an engine already on this Mac and returns the version it
    /// carried: `dormison-r<N>.tar.xz` as the release ships it, or the
    /// directory `package-engine.sh` assembled, which is what is inside that
    /// tarball. Either way the version has to be new — an installed engine is
    /// never replaced.
    ///
    /// `requiringSignature` is for a file nobody chose: the copy found beside
    /// the app is installed only with a `.sig` that verifies against the
    /// pinned key. A file a person picked or named may go unsigned.
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

    /// An engine tree built here: named for its version, holding `wine/bin`,
    /// and left where its author put it — the copy is staged and moved in, so
    /// an interrupted one never leaves a half tree that reads as installed.
    /// `cp` rather than `rsync`, which maps each file it reads and so gets a
    /// process running a signed Mach-O under Rosetta killed.
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
        let destination = root.appendingPathComponent(version)
        guard !manager.fileExists(atPath: destination.path) else {
            throw InstallError("engine \(version) is already installed")
        }
        progress("Copying \(version)…", nil)
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

    /// A `<name>.sig` beside the tarball is verified against the pinned key,
    /// and one that fails refuses the install; a tarball with nothing beside
    /// it is the operator's own choice and is installed as such, logged,
    /// unless a signature is required. The tarball's single top-level
    /// directory names the version.
    private static func install(
        fromTarball tarball: URL, into root: URL, requiringSignature: Bool,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws -> String {
        let manager = FileManager.default
        let named = versionName(of: tarball)
        guard !manager.fileExists(atPath: root.appendingPathComponent(named).path) else {
            throw InstallError("engine \(named) is already installed")
        }
        progress("Verifying \(tarball.lastPathComponent)…", nil)
        let signatureURL = EngineSignature.signatureURL(for: tarball)
        if let signatureFile = try? Data(contentsOf: signatureURL) {
            try EngineSignature.verify(file: tarball, signatureFile: signatureFile)
            SetupLog.log("engine tarball \(tarball.lastPathComponent): signature verified")
        } else if requiringSignature {
            throw EngineSignature.Failure.signatureMissing(signatureURL)
        } else {
            SetupLog.log("engine tarball \(tarball.lastPathComponent): no .sig beside it, installed as the operator's own")
        }
        progress("Installing…", nil)
        let staging = try makeStaging()
        defer { try? manager.removeItem(at: staging) }
        return try await unpack(tarball, expecting: nil, in: staging, into: root)
    }

    /// The engine a tarball is named for: `dormison-r3.tar.xz` → `dormison-r3`.
    static func versionName(of tarball: URL) -> String {
        var name = tarball.lastPathComponent
        for suffix in [".tar.xz", ".txz", ".tar"] where name.hasSuffix(suffix) {
            name.removeLast(suffix.count)
            break
        }
        return name
    }

    /// An engine tarball shipped with this copy of the app, so a disk image
    /// can carry the engine and setup needs no download: in
    /// `Contents/Resources/Engine/`, or beside the app bundle — the disk
    /// image's root while the app runs from it. Only a tarball with its
    /// `.sig` beside it counts: the folder beside the app is often Downloads
    /// or /Applications, where any file can land. The newest release wins
    /// when there are several.
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
        return candidates.max {
            versionName(of: $0).localizedStandardCompare(versionName(of: $1)) == .orderedAscending
        }
    }

    /// The engine this copy of the app carries, when it is newer than every managed engine
    /// installed: an app update that brings a newer engine hands it over. Nil before setup
    /// (setup installs the bundled one itself) and when the newest installed is as new.
    static func bundledUpgrade(bundled: URL? = bundledTarball(), installed: [String]) -> URL? {
        guard let bundled, let newest = installed.max(by: {
            $0.localizedStandardCompare($1) == .orderedAscending
        }) else { return nil }
        let version = versionName(of: bundled)
        guard !installed.contains(version),
              version.localizedStandardCompare(newest) == .orderedDescending else { return nil }
        return bundled
    }

    private static func makeStaging() throws -> URL {
        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("sevo-engine-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        return staging
    }

    /// Extracts `tarball` under `staging` and moves its single top-level
    /// directory — the engine version — into `root`. With `expected`, the
    /// directory has to be that version; the tree has to carry `wine/bin`,
    /// what ``Engine/existsOnDisk`` looks for, or it is not an engine.
    private static func unpack(
        _ tarball: URL, expecting expected: String?, in staging: URL, into root: URL,
    ) async throws -> String {
        let manager = FileManager.default
        let extracted = staging.appendingPathComponent("extracted")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        // Through a pipe: tar reading the file itself copies the archive's quarantine onto
        // every file it writes, and an ad-hoc signed binary carrying it never gets past exec.
        // A disk image that came by browser or AirDrop quarantines the tarball inside the app.
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
        let destination = root.appendingPathComponent(version)
        guard !manager.fileExists(atPath: destination.path) else {
            throw InstallError("engine \(version) is already installed")
        }
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        try manager.moveItem(at: tree, to: destination)
        return version
    }

    /// Makes the extracted tree its owner's to change and leaves no file quarantined. Checked
    /// before anything in it runs: Gatekeeper keeps the verdict it gave an executed binary, so
    /// a flag removed afterwards no longer helps.
    static func clearQuarantine(under root: URL) async throws {
        _ = await Subprocess.run("/bin/chmod", ["-R", "u+w", root.path])
        let stuck = removeQuarantine(under: root)
        guard stuck.isEmpty else {
            throw InstallError("engine files still quarantined: \(stuck.prefix(3).joined(separator: ", "))")
        }
    }

    /// Strips the quarantine flag from every file under `root`, answering the ones it stayed on.
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

    /// Downloads the tarball with real progress: a plain download task whose
    /// `Progress` is observed, the same shape the GPTk panel uses. Never an
    /// `AsyncBytes` loop: it costs an await per byte, which turns seconds
    /// into minutes. The temp file must be moved inside the completion
    /// handler — URLSession deletes it when the handler returns.
    ///
    /// Cancelling the calling task cancels the transfer, and a response other
    /// than 2xx fails the download with its status rather than handing an
    /// error page to the size check.
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
                    // The response may not carry a length; the manifest's
                    // declared size stands in.
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

    /// One download's task and progress observation, held until the
    /// completion handler runs. A cancel that arrives before the task exists
    /// is remembered, and the task is cancelled the moment it starts.
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

    /// Streaming SHA-256 — engine tarballs are hundreds of MB.
    static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private struct InstallError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) {
            self.description = description
        }
    }
}
