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
    /// Idempotent: an already-installed version returns immediately.
    static func install(
        _ release: EngineManifest.Release,
        progress: @Sendable (String) -> Void = { _ in },
    ) async throws {
        guard !isInstalled(release) else { return }
        let manager = FileManager.default
        let staging = manager.temporaryDirectory
            .appendingPathComponent("sevo-engine-\(UUID().uuidString)")
        try manager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: staging) }

        progress("Downloading the engine (~\(release.sizeBytes / 1_000_000) MB)…")
        let (downloaded, _) = try await URLSession.shared.download(from: release.url)
        let tarball = staging.appendingPathComponent("engine.tar.xz")
        try manager.moveItem(at: downloaded, to: tarball)

        progress("Verifying…")
        let digest = try sha256(of: tarball)
        guard digest == release.sha256.lowercased() else {
            throw InstallError("engine tarball hash mismatch: \(digest)")
        }

        progress("Installing…")
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

/// The steamwebhelper wrapper a managed engine needs: the real
/// `steamwebhelper.exe` is renamed aside and a tiny compiled wrapper takes
/// its place, re-execing the original with the CEF flags OSS Wine needs or
/// the client renders black (`Tools/webhelper-wrapper/`, the vineport-proven
/// recipe). Steam's self-updater replaces the wrapper with a fresh real exe,
/// so the supervisor re-verifies on every client start.
nonisolated enum WebhelperWrapper {
    /// Where the real exe is parked; the wrapper re-execs this name.
    static let realName = "steamwebhelper.real.exe"
    /// Embedded in the wrapper binary; its presence distinguishes our
    /// wrapper from a genuine steamwebhelper.exe.
    static let marker = "sevoflurane-webhelper-wrapper"

    static func webhelperDirectory(inBottle bottle: URL) -> URL {
        SteamBottle.steamRoot(inBottle: bottle).appendingPathComponent("bin/cef/cef.win64")
    }

    enum State: Equatable, Sendable {
        /// The wrapper sits in place and the real exe is parked next to it.
        case applied
        /// A genuine steamwebhelper.exe sits unwrapped (fresh install, or a
        /// client self-update replaced the wrapper).
        case unapplied
        /// No steamwebhelper.exe at all — the client isn't installed.
        case missing
    }

    static func state(inBottle bottle: URL) -> State {
        let directory = webhelperDirectory(inBottle: bottle)
        let exe = directory.appendingPathComponent("steamwebhelper.exe")
        guard let data = try? Data(contentsOf: exe) else { return .missing }
        return data.range(of: Data(marker.utf8)) != nil ? .applied : .unapplied
    }

    /// Parks the genuine exe and installs the wrapper. A leftover parked
    /// copy from before a self-update is replaced — the freshly updated exe
    /// is the one that must run.
    static func apply(from engine: Engine, toBottle bottle: URL) throws {
        guard let wrapper = engine.webhelperWrapperURL else { return }
        guard state(inBottle: bottle) == .unapplied else { return }
        let manager = FileManager.default
        let directory = webhelperDirectory(inBottle: bottle)
        let exe = directory.appendingPathComponent("steamwebhelper.exe")
        let real = directory.appendingPathComponent(realName)
        if manager.fileExists(atPath: real.path) {
            try manager.removeItem(at: real)
        }
        try manager.moveItem(at: exe, to: real)
        try manager.copyItem(at: wrapper, to: exe)
    }
}
