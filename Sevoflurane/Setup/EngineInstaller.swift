import CryptoKit
import Foundation

/// Downloads, verifies, and installs a managed engine release into
/// `Engines/<version>/`. The download lands in a
/// temporary directory and only an integrity-verified, fully extracted tree
/// is moved into place — a version directory either exists complete or not
/// at all, which is what lets ``SetupProbe/managedEngineVersions()`` treat
/// presence as installed.
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
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-engine-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
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
        let extracted = staging.appendingPathComponent("extracted")
        try manager.createDirectory(at: extracted, withIntermediateDirectories: true)
        let untar = await Subprocess.run(
            "/usr/bin/tar", ["-xJf", tarball.path, "-C", extracted.path],
            capture: .combined, timeout: .seconds(600),
        )
        guard untar.status == 0 else {
            throw InstallError("engine extraction failed: \(untar.output.suffix(200))")
        }

        // The tarball's single top-level directory is the version.
        let contents = try manager.contentsOfDirectory(atPath: extracted.path)
            .filter { !$0.hasPrefix(".") }
        guard contents == [release.version] else {
            throw InstallError("engine tarball layout unexpected: \(contents)")
        }
        try manager.createDirectory(at: Engine.managedRoot, withIntermediateDirectories: true)
        try manager.moveItem(
            at: extracted.appendingPathComponent(release.version),
            to: Engine.managedRoot.appendingPathComponent(release.version),
        )
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
