import Foundation

/// The Windows pieces games assume are present and a fresh prefix lacks —
/// CrossOver's own Steam bottle recipe ("Game Launcher Dependencies",
/// c4.21822 in its profile database) distilled, plus the two heavyweights
/// older games ask for. Every install is silent and idempotent: downloads go
/// to the bottle's own temp, installers run inside the bottle through the
/// same engine invocation as the client, and "installed" is judged by what
/// landed on disk rather than by exit codes.
nonisolated enum BottleDependencies {
    struct Dependency: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        /// The symptom this fixes — how a user recognizes they need it.
        let detail: String
        /// Rough download size, for the row's fine print.
        let download: String
        /// Whether a bottle without it is incomplete rather than merely
        /// missing a nicety. A required entry is one a modern title links
        /// against or compiles shaders with; the rest are legacy runtimes and
        /// fonts, whose absence costs glyphs and old titles, not launches.
        /// Nothing gates a launch on either kind.
        let required: Bool
    }

    static let catalog: [Dependency] = [
        Dependency(
            id: "corefonts", name: "Core fonts",
            detail: "Fixes blank labels and boxes in launchers and older games.",
            download: "4 MB", required: false,
        ),
        Dependency(
            id: "vcredist", name: "Visual C++ runtime (2015–2022)",
            detail: "Fixes \u{201C}VCRUNTIME140.dll was not found\u{201D} and "
                + "\u{201C}MSVCP140.dll is missing\u{201D} at launch.",
            download: "38 MB", required: true,
        ),
        Dependency(
            id: "d3dcompiler", name: "Direct3D shader compiler",
            detail: "Fixes shader errors, black screens, and crashes while "
                + "a Direct3D game compiles its shaders.",
            download: "8 MB", required: true,
        ),
        Dependency(
            id: "directx2010", name: "DirectX runtimes (June 2010)",
            detail: "Fixes a d3dx9_43.dll error, and silent audio in games "
                + "built on old XAudio and XACT.",
            download: "96 MB", required: false,
        ),
        Dependency(
            id: "cjkfonts", name: "Japanese, Chinese & Korean fonts",
            detail: "Shows Japanese, Chinese, and Korean text. Source Han "
                + "Sans, all four regions.",
            download: "220 MB", required: false,
        ),
    ]

    /// The required entries a bottle is missing — what "bottle incomplete"
    /// means everywhere it is said.
    static func missingRequired() -> [Dependency] {
        catalog.filter { $0.required && !isInstalled($0) }
    }

    // MARK: - What a new bottle gets

    /// Whether setting up a bottle installs the whole catalog rather than the
    /// required entries alone.
    ///
    /// On by default: the optional entries are the ones whose absence shows up
    /// as a symptom nobody can trace — boxes instead of glyphs, silent audio,
    /// an old title that names a d3dx9 file. A few hundred megabytes during a
    /// setup that is already downloading Steam buys a bottle that does not ask
    /// again.
    static var installsEverything: Bool {
        get { Preferences.shared.object(forKey: everythingKey) as? Bool ?? true }
        set { Preferences.shared.set(newValue, forKey: everythingKey) }
    }

    private static let everythingKey = "installAllDependencies"

    /// What provisioning installs, in catalog order.
    static func provisioned(all: Bool = installsEverything) -> [Dependency] {
        catalog.filter { $0.required || all }
    }

    // MARK: - Detection

    static func isInstalled(_ dependency: Dependency) -> Bool {
        switch dependency.id {
        case "corefonts":
            fontsDirectoryContains(prefix: "arial.ttf")
        case "vcredist":
            hasRealDLL("vcruntime140.dll")
        case "d3dcompiler":
            hasRealDLL("d3dcompiler_47.dll")
        case "directx2010":
            hasRealDLL("d3dx9_43.dll")
        case "cjkfonts":
            fontsDirectoryContains(prefix: "sourcehansans")
        default:
            false
        }
    }

    private static var driveC: URL { SteamBottle.root.appendingPathComponent("drive_c") }
    private static var fontsDirectory: URL { driveC.appendingPathComponent("windows/Fonts") }
    private static var system32: URL { driveC.appendingPathComponent("windows/system32") }
    private static var syswow64: URL { driveC.appendingPathComponent("windows/syswow64") }
    /// Downloads and extractions, inside the bottle so installers can see
    /// them at a plain `C:` path.
    private static var scratchRoot: URL { driveC.appendingPathComponent("windows/temp/sevo-deps") }
    private static let scratchRootWindowsPath = #"C:\windows\temp\sevo-deps"#

    /// One install's own directory under the scratch root, in both the paths
    /// it is addressed by. Each install creates one and removes that one:
    /// a directory shared between installs is deleted out from under whoever
    /// is still downloading into it, which reads afterwards as a move that
    /// found no destination, or an installer that could not find the files it
    /// had just extracted.
    ///
    /// `root` is the bottle's scratch directory; tests give it one of their
    /// own, since a scratch that answers a Windows path only exists inside a
    /// prefix.
    struct Scratch {
        let url: URL
        let windowsPath: String

        init(id: String, root: URL? = nil) {
            let name = "\(id)-\(UUID().uuidString.prefix(8))"
            url = (root ?? BottleDependencies.scratchRoot).appendingPathComponent(name)
            windowsPath = "\(BottleDependencies.scratchRootWindowsPath)\\\(name)"
        }

        func directory(_ relative: String) -> URL {
            url.appendingPathComponent(relative)
        }

        func windowsPath(_ relative: String) -> String {
            "\(windowsPath)\\\(relative)"
        }

        func remove() {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private static func fontsDirectoryContains(prefix: String) -> Bool {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: fontsDirectory.path)) ?? []
        return names.contains { $0.lowercased().hasPrefix(prefix) }
    }

    /// A DLL that exists and is the genuine article. Wine stamps its
    /// stand-in PE files near the DOS header — "Wine placeholder DLL"
    /// (CrossOver) or "Wine builtin DLL" (upstream) — so a fresh prefix's
    /// fake file doesn't read as an installed redistributable.
    private static func hasRealDLL(_ name: String) -> Bool {
        let url = system32.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 0x200), !data.isEmpty else { return false }
        let markers = ["Wine placeholder DLL", "Wine builtin DLL"]
        return !markers.contains { data.range(of: Data($0.utf8)) != nil }
    }

    // MARK: - Install

    /// Installs one catalog entry, narrating stages through `phase`.
    /// Answers a failure description, or `nil` when the pieces landed.
    ///
    /// Installs run one at a time however many are asked for at once: they
    /// run installers inside one prefix, against one registry, and the two
    /// download hosts rate-limit a burst of parallel requests. The queue is
    /// first-come, so a second install waits with `phase` reading `waiting`
    /// rather than starting and failing.
    static func install(
        _ id: String, phase: @escaping @Sendable (String) -> Void,
    ) async -> String? {
        await InstallQueue.shared.enqueue {
            await perform(id, phase: phase)
        } waiting: {
            phase("waiting for the other install to finish")
        }
    }

    @concurrent
    private static func perform(
        _ id: String, phase: @escaping @Sendable (String) -> Void,
    ) async -> String? {
        let scratch = Scratch(id: id)
        defer { scratch.remove() }
        do {
            switch id {
            case "corefonts": try await installCoreFonts(scratch: scratch, phase: phase)
            case "vcredist": try await installVCRedist(scratch: scratch, phase: phase)
            case "d3dcompiler": try await installD3DCompiler(scratch: scratch, phase: phase)
            case "directx2010": try await installDirectX2010(scratch: scratch, phase: phase)
            case "cjkfonts": try await installCJKFonts(scratch: scratch, phase: phase)
            default: return "unknown dependency \(id)"
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// The one lane every install passes through, in arrival order.
    actor InstallQueue {
        static let shared = InstallQueue()
        private var tail: Task<Void, Never>?
        private var queued = 0

        /// Runs `body` after everything already queued. `waiting` is called
        /// when the job does not start at once, so a queued row can say so.
        func enqueue(
            _ body: @escaping @Sendable () async -> String?,
            waiting: @Sendable () -> Void,
        ) async -> String? {
            let previous = tail
            if queued > 0 { waiting() }
            queued += 1
            let job = Task {
                await previous?.value
                return await body()
            }
            tail = Task { _ = await job.value }
            let failure = await job.value
            queued -= 1
            return failure
        }
    }

    private struct InstallFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// The eleven classic self-extracting font archives, from the mirror
    /// winetricks uses. Each extracts with the `/T: /C /Q` flags CrossOver's
    /// profile records, then the faces are copied into the bottle's Fonts —
    /// Wine registers everything it finds there on its own.
    private static func installCoreFonts(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        let archives = [
            "andale32.exe", "arial32.exe", "arialb32.exe", "comic32.exe",
            "courie32.exe", "georgi32.exe", "impact32.exe", "times32.exe",
            "trebuc32.exe", "verdan32.exe", "webdin32.exe",
        ]
        let extracted = scratch.directory("fonts")
        for (index, archive) in archives.enumerated() {
            phase("downloading fonts (\(index + 1) of \(archives.count))")
            let file = try await download(
                "https://github.com/pushcx/corefonts/raw/master/\(archive)",
                as: archive, into: scratch,
            )
            let result = await ClientLifecycle.runSupervisedInBottle([
                SteamBottle.windowsPath(for: file),
                "/T:\(scratch.windowsPath("fonts"))", "/C", "/Q",
            ], timeout: .seconds(120))
            guard result.status == 0 else {
                throw InstallFailure(message: "\(archive) refused to extract")
            }
        }
        phase("installing fonts")
        try copyFonts(from: extracted, matching: ["ttf", "ttc"])
    }

    /// Microsoft's evergreen 14.x redistributable, both architectures, run
    /// with its documented silent flags, then the 140-family DLL overrides so
    /// the installed files actually win over Wine's builtins.
    private static func installVCRedist(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        for arch in ["x64", "x86"] {
            phase("downloading VC++ (\(arch))")
            let installer = try await download(
                "https://aka.ms/vs/17/release/vc_redist.\(arch).exe",
                as: "vc_redist.\(arch).exe", into: scratch,
            )
            phase("installing VC++ (\(arch))")
            let result = await ClientLifecycle.runSupervisedInBottle([
                SteamBottle.windowsPath(for: installer),
                "/install", "/quiet", "/norestart",
            ])
            // 1638: a newer version is already installed. 3010: success,
            // wants a reboot it won't get and doesn't need.
            guard let status = result.status, [0, 1638, 3010].contains(Int(status)) else {
                throw InstallFailure(message: "vc_redist.\(arch).exe failed "
                    + "(\(result.status.map(String.init) ?? "no exit"))")
            }
        }
        phase("setting DLL overrides")
        let family = [
            "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
            "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140",
            "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
        ]
        try await importOverrides(family.map { ($0, "native,builtin") }, scratch: scratch)
    }

    /// The two fxc2 builds of d3dcompiler_47, copied straight over Wine's
    /// stand-ins — CrossOver's own trick, and with the fake file gone no
    /// registry override is needed.
    ///
    /// Both are addressed by the commit that built them and checked against
    /// the digest of what that commit holds: this DLL is copied over a system
    /// DLL and then compiles every shader a game asks for, so what it is has
    /// to be a fact rather than whatever a branch points at today.
    private static func installD3DCompiler(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        phase("downloading d3dcompiler_47")
        let x64 = try await download(
            "\(fxc2Revision)/dll/d3dcompiler_47.dll",
            as: "d3dcompiler_47.dll", into: scratch,
            sha256: "4432bbd1a390874f3f0a503d45cc48d346abc3a8c0213c289f4b615bf0ee84f3",
        )
        let x86 = try await download(
            "\(fxc2Revision)/dll/d3dcompiler_47_32.dll",
            as: "d3dcompiler_47_32.dll", into: scratch,
            sha256: "2ad0d4987fc4624566b190e747c9d95038443956ed816abfd1e2d389b5ec0851",
        )
        phase("installing d3dcompiler_47")
        try replaceFile(at: system32.appendingPathComponent("d3dcompiler_47.dll"), with: x64)
        try replaceFile(at: syswow64.appendingPathComponent("d3dcompiler_47.dll"), with: x86)
    }

    /// The last classic DirectX redistributable: self-extracts, then its own
    /// DXSETUP lays down d3dx9, XAudio, XACT and X3DAudio for both
    /// architectures.
    private static func installDirectX2010(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        phase("downloading DirectX redistributable")
        let redist = try await download(
            "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
            as: "directx_Jun2010_redist.exe", into: scratch,
        )
        phase("extracting")
        let extract = await ClientLifecycle.runSupervisedInBottle([
            SteamBottle.windowsPath(for: redist),
            "/Q", "/T:\(scratch.windowsPath("dx"))",
        ], timeout: .seconds(300))
        guard extract.status == 0 else {
            throw InstallFailure(message: "the redistributable refused to extract")
        }
        phase("running DXSETUP")
        let setup = await ClientLifecycle.runSupervisedInBottle([
            scratch.windowsPath(#"dx\DXSETUP.exe"#), "/silent",
        ], timeout: .seconds(900))
        guard setup.status == 0 else {
            throw InstallFailure(message: "DXSETUP failed "
                + "(\(setup.status.map(String.init) ?? "no exit"))")
        }
    }

    /// Source Han Sans, the four regional builds CrossOver's Asian-fonts
    /// component ships, from Adobe's pinned release.
    private static func installCJKFonts(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        let regions = ["J", "SC", "TC", "K"]
        for (index, region) in regions.enumerated() {
            phase("downloading fonts (\(index + 1) of \(regions.count))")
            let zip = try await download(
                "https://github.com/adobe-fonts/source-han-sans/releases/download/2.004R/SourceHanSans\(region).zip",
                as: "SourceHanSans\(region).zip", into: scratch,
            )
            phase("installing fonts (\(index + 1) of \(regions.count))")
            let result = await Subprocess.run(
                "/usr/bin/unzip",
                ["-jo", zip.path, "*.otf", "-d", fontsDirectory.path],
                capture: .combined, timeout: .seconds(300),
            )
            guard result.status == 0 else {
                throw InstallFailure(message: "SourceHanSans\(region).zip refused to unzip")
            }
            try? FileManager.default.removeItem(at: zip)
        }
    }

    // MARK: - DLL overrides

    struct Override: Identifiable, Sendable, Equatable {
        let dll: String
        let mode: String
        var id: String { dll }
    }

    /// The load-order modes Wine accepts, in the order someone reaches for
    /// them.
    static let overrideModes = ["native,builtin", "native", "builtin", "disabled"]

    /// The bottle's global overrides, read from `user.reg`. The file lags
    /// wineserver's in-memory registry by a few seconds after a write, so
    /// callers that just wrote should trust what they wrote.
    static func overrides() -> [Override] {
        let file = SteamBottle.root.appendingPathComponent("user.reg")
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        var found: [Override] = []
        var inSection = false
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("[") {
                inSection = line.hasPrefix(#"[Software\\Wine\\DllOverrides]"#)
                continue
            }
            guard inSection, line.hasPrefix("\"") else { continue }
            let parts = line.components(separatedBy: "\"=\"")
            guard parts.count == 2 else { continue }
            let dll = String(parts[0].dropFirst())
            let mode = String(parts[1].dropLast(parts[1].hasSuffix("\"") ? 1 : 0))
            found.append(Override(dll: dll, mode: mode.isEmpty ? "disabled" : mode))
        }
        return found.sorted { $0.dll < $1.dll }
    }

    static func setOverride(dll: String, mode: String) async -> String? {
        let result = await ClientLifecycle.runSupervisedInBottle([
            "reg", "add", #"HKCU\Software\Wine\DllOverrides"#,
            "/v", dll, "/d", mode == "disabled" ? "" : mode, "/f",
        ], timeout: .seconds(60))
        return result.status == 0 ? nil : "reg add failed: \(result.output.suffix(120))"
    }

    static func removeOverride(dll: String) async -> String? {
        let result = await ClientLifecycle.runSupervisedInBottle([
            "reg", "delete", #"HKCU\Software\Wine\DllOverrides"#,
            "/v", dll, "/f",
        ], timeout: .seconds(60))
        return result.status == 0 ? nil : "reg delete failed: \(result.output.suffix(120))"
    }

    // MARK: - Plumbing

    /// The fxc2 commit the two d3dcompiler builds are taken from, as a raw
    /// content URL prefix.
    private static let fxc2Revision =
        "https://raw.githubusercontent.com/mozilla/fxc2/9aba9b11079303d5577e0e3eb455f4d00f3b5946"

    /// How long a download waits after the first refusal and after the
    /// second — so three attempts in all. Both hosts these files come from
    /// rate-limit a burst, and a burst is what a user pressing every Install
    /// button makes.
    static let downloadBackoff: [Duration] = [.seconds(2), .seconds(8)]

    /// Fetches one file into this install's scratch directory, retrying a
    /// host that is rate-limiting or briefly broken. `sha256` is the digest
    /// the bytes must have, lowercase hex; a file that does not match it is
    /// refused rather than copied over a system DLL. `session` and `backoff`
    /// are what a test replaces to drive the retries without a network.
    static func download(
        _ url: String, as name: String, into scratch: Scratch, sha256: String? = nil,
        session: URLSession = .shared, backoff: [Duration] = downloadBackoff,
    ) async throws -> URL {
        guard let source = URL(string: url) else {
            throw InstallFailure(message: "bad URL \(url)")
        }
        var lastFailure = InstallFailure(message: "\(name): no attempt was made")
        for attempt in 0 ... backoff.count {
            do {
                return try await fetch(
                    source, as: name, into: scratch, sha256: sha256, session: session,
                )
            } catch let failure as RetryableDownload {
                lastFailure = InstallFailure(message: failure.message)
            }
            if attempt < backoff.count {
                try? await Task.sleep(for: backoff[attempt])
            }
        }
        throw lastFailure
    }

    /// A refusal worth waiting out: the host is rate-limiting (429), is
    /// briefly broken (5xx), or the transfer itself failed.
    private struct RetryableDownload: Error {
        let message: String
    }

    private static func fetch(
        _ source: URL, as name: String, into scratch: Scratch, sha256: String?,
        session: URLSession,
    ) async throws -> URL {
        // The destination directory exists before the transfer does, so the
        // move at the end has somewhere to land.
        try FileManager.default.createDirectory(
            at: scratch.url, withIntermediateDirectories: true,
        )
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await session.download(from: source)
        } catch {
            throw RetryableDownload(message: "\(name): \(error.localizedDescription)")
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = "\(name): HTTP \(http.statusCode)"
            guard http.statusCode == 429 || http.statusCode >= 500 else {
                throw InstallFailure(message: message)
            }
            throw RetryableDownload(message: message)
        }
        if let sha256 {
            let digest = try FileDigest.sha256(of: temp)
            guard digest == sha256 else {
                try? FileManager.default.removeItem(at: temp)
                throw InstallFailure(
                    message: "\(name): the download is not the file it should be "
                        + "(sha256 \(digest))")
            }
        }
        // Again, because the move is where a missing directory is felt: the
        // transfer landed in the session's own temp, and the file only enters
        // the bottle here.
        try FileManager.default.createDirectory(
            at: scratch.url, withIntermediateDirectories: true,
        )
        let destination = scratch.directory(name)
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.moveItem(at: temp, to: destination)
        return destination
    }


    private static func replaceFile(at destination: URL, with source: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    private static func copyFonts(from directory: URL, matching extensions: [String]) throws {
        let names = (try? FileManager.default
            .contentsOfDirectory(atPath: directory.path)) ?? []
        let faces = names.filter { name in
            extensions.contains { name.lowercased().hasSuffix(".\($0)") }
        }
        guard !faces.isEmpty else {
            throw InstallFailure(message: "no font files came out of the archives")
        }
        try FileManager.default.createDirectory(
            at: fontsDirectory, withIntermediateDirectories: true,
        )
        for face in faces {
            try replaceFile(
                at: fontsDirectory.appendingPathComponent(face),
                with: directory.appendingPathComponent(face),
            )
        }
    }

    /// One `regedit /S` import for a batch of overrides — eleven `reg add`
    /// spawns collapsed into one.
    private static func importOverrides(
        _ entries: [(dll: String, mode: String)], scratch: Scratch,
    ) async throws {
        let body = entries.map { "\"\($0.dll)\"=\"\($0.mode)\"" }.joined(separator: "\n")
        let regFile = scratch.directory("overrides.reg")
        let contents = """
        Windows Registry Editor Version 5.00

        [HKEY_CURRENT_USER\\Software\\Wine\\DllOverrides]
        \(body)
        """
        try FileManager.default.createDirectory(
            at: scratch.url, withIntermediateDirectories: true,
        )
        try contents.write(to: regFile, atomically: true, encoding: .utf8)
        let result = await ClientLifecycle.runSupervisedInBottle([
            "regedit", "/S", SteamBottle.windowsPath(for: regFile),
        ], timeout: .seconds(60))
        guard result.status == 0 else {
            throw InstallFailure(message: "regedit refused the overrides import")
        }
    }
}
