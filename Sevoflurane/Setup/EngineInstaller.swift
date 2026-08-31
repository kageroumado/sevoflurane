import CryptoKit
import Foundation

/// Downloads, verifies, and installs a managed engine release into
/// `Engines/<version>/` (release-plan R2.2). The download lands in a
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

    /// Download → sha256 verify → extract → atomic move into place.
    /// Idempotent: an already-installed version returns immediately. The
    /// fraction is the download's progress against the manifest's declared
    /// size, or `nil` for the phases with no measurable whole.
    static func install(
        _ release: EngineManifest.Release,
        progress: @Sendable (String, Double?) -> Void = { _, _ in },
    ) async throws {
        guard !isInstalled(release) else { return }
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
        let digest = try sha256(of: tarball)
        guard digest == release.sha256.lowercased() else {
            throw InstallError("engine tarball hash mismatch: \(digest)")
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

    /// Streams the tarball to disk, reporting the fraction received against
    /// the manifest's declared size every few MB. `URLSession.download`'s
    /// progress lives on a delegate; this stays structured instead.
    private static func download(
        _ release: EngineManifest.Release, to tarball: URL,
        label: String, progress: @Sendable (String, Double?) -> Void,
    ) async throws {
        progress(label, 0)
        let (bytes, _) = try await URLSession.shared.bytes(from: release.url)
        FileManager.default.createFile(atPath: tarball.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tarball)
        defer { try? handle.close() }
        var buffer = Data(capacity: 1 << 20)
        var received: Int64 = 0
        var reported: Int64 = 0
        for try await byte in bytes {
            buffer.append(byte)
            guard buffer.count >= 1 << 20 else { continue }
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            buffer.removeAll(keepingCapacity: true)
            if received - reported >= 4 << 20 {
                reported = received
                progress(label, min(1, Double(received) / Double(release.sizeBytes)))
            }
        }
        try handle.write(contentsOf: buffer)
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
