import CryptoKit
import Foundation

/// Downloads, verifies, and installs a managed engine release into
/// `Engines/<version>/`. The download lands in a
/// temporary directory and only an integrity-verified, fully extracted tree
/// is moved into place — a version directory either exists complete or not
/// at all, which is what lets ``SetupProbe/managedEngineVersions()`` treat
/// presence as installed.
///
/// The tarball can also come from disk, ``install(fromFile:into:progress:)``:
/// the release asset someone saved by hand on a Mac the release feed does
/// not reach, or the copy a disk image ships with the app
/// (``bundledTarball(resources:beside:)``).
nonisolated enum EngineInstaller {
    /// Fetches the manifest's stable release, or reports why the machine
    /// can't use it.
    static func stableRelease() async throws -> EngineManifest.Release {
        guard let release = try await EngineManifest.fetch().stable else {
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

    /// Installs the engine tarball at `tarball` — `dormison-r<N>.tar.xz` as
    /// the release ships it — and returns the version it carried. A
    /// `<name>.sig` beside the file is verified against the pinned key, and
    /// one that fails refuses the install; a tarball with nothing beside it
    /// is the operator's own choice and is installed as such, logged. The
    /// tarball's single top-level directory names the version, and the
    /// version has to be new: an installed engine is never replaced.
    static func install(
        fromFile tarball: URL,
        into root: URL = Engine.managedRoot,
        progress: @escaping @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws -> String {
        let manager = FileManager.default
        guard manager.fileExists(atPath: tarball.path) else {
            throw InstallError("no engine tarball at \(tarball.path)")
        }
        let named = versionName(of: tarball)
        guard !manager.fileExists(atPath: root.appendingPathComponent(named).path) else {
            throw InstallError("engine \(named) is already installed")
        }
        progress("Verifying \(tarball.lastPathComponent)…", nil)
        let signatureURL = EngineSignature.signatureURL(for: tarball)
        if let signatureFile = try? Data(contentsOf: signatureURL) {
            try EngineSignature.verify(file: tarball, signatureFile: signatureFile)
            SetupLog.log("engine tarball \(tarball.lastPathComponent): signature verified")
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
    /// image's root while the app runs from it. The newest release wins
    /// when there are several.
    static func bundledTarball(
        resources: URL? = Bundle.main.resourceURL,
        beside bundle: URL = Bundle.main.bundleURL,
    ) -> URL? {
        let places = [resources?.appendingPathComponent("Engine"), bundle.deletingLastPathComponent()]
            .compactMap(\.self)
        let candidates = places.flatMap { place in
            ((try? FileManager.default.contentsOfDirectory(atPath: place.path)) ?? [])
                .filter { $0.hasPrefix("dormison-") && $0.hasSuffix(".tar.xz") }
                .map(place.appendingPathComponent)
        }
        return candidates.max {
            versionName(of: $0).localizedStandardCompare(versionName(of: $1)) == .orderedAscending
        }
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
        let untar = await Subprocess.run(
            "/usr/bin/tar", ["-xf", tarball.path, "-C", extracted.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard untar.status == 0 else {
            throw InstallError("engine extraction failed: \(untar.output.suffix(200))")
        }

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

    /// Downloads the tarball with real progress: a plain download task whose
    /// `Progress` is observed, the same shape the GPTk panel uses. (An
    /// `AsyncBytes` loop crawls — per-byte iteration costs an await per byte,
    /// minutes for a tarball a plain download moves in seconds.) The temp file
    /// must be moved inside the completion handler —
    /// URLSession deletes it when the handler returns.
    private static func download(
        _ release: EngineManifest.Release, to tarball: URL,
        label: String, progress: @escaping @Sendable (String, Double?) -> Void,
    ) async throws {
        progress(label, 0)
        let declaredBytes = release.sizeBytes
        // Keeps the KVO observation alive until the completion handler runs —
        // the handler captures the box, the box holds the observation.
        final class ObservationBox: @unchecked Sendable {
            var observation: NSKeyValueObservation?
        }
        let box = ObservationBox()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            let task = URLSession.shared.downloadTask(with: release.url) { temp, _, error in
                box.observation?.invalidate()
                box.observation = nil
                if let error {
                    continuation.resume(throwing: error)
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
            box.observation = task.progress.observe(\.fractionCompleted) { taskProgress, _ in
                // The response may not carry a length; the manifest's
                // declared size stands in.
                let fraction = taskProgress.totalUnitCount > 0
                    ? taskProgress.fractionCompleted
                    : Double(taskProgress.completedUnitCount) / Double(declaredBytes)
                guard fraction - lastReported >= 0.01 || fraction >= 1 else { return }
                lastReported = fraction
                progress(label, min(1, fraction))
            }
            task.resume()
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
