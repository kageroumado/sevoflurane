import Foundation

/// The Windows pieces games assume and a fresh prefix lacks, after
/// CrossOver's "Game Launcher Dependencies" recipe. Installs are silent and
/// idempotent, and "installed" is judged by what landed on disk.
nonisolated enum BottleDependencies {
    struct Dependency: Identifiable, Sendable, Equatable {
        let id: String
        let name: String
        /// The symptom this fixes.
        let detail: String
        let download: String
        /// Whether a bottle without it is incomplete: modern titles link
        /// against it. Nothing gates a launch on it.
        let required: Bool

        init(id: String, name: String, detail: String, download: String, required: Bool) {
            self.id = id
            self.name = InterfaceCopy.localized(name)
            self.detail = InterfaceCopy.localized(detail)
            self.download = download
            self.required = required
        }
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
            detail: "Fixes shader errors, black screens, and crashes while shaders compile.",
            download: "8 MB", required: true,
        ),
        Dependency(
            id: "directx2010", name: "DirectX runtimes (June 2010)",
            detail: "Fixes a d3dx9_43.dll error, and silent audio in games "
                + "built on old XAudio and XACT.",
            download: "96 MB", required: false,
        ),
        Dependency(
            id: "cjkfonts", name: "Japanese, Chinese, and Korean fonts",
            detail: "Source Han Sans, all four regions.",
            download: "220 MB", required: false,
        ),
    ]

    /// The required entries a bottle is missing ("bottle incomplete").
    static func missingRequired() -> [Dependency] {
        catalog.filter { $0.required && !isInstalled($0) }
    }

    // MARK: - What a new bottle gets

    /// Whether bottle setup installs the whole catalog. On by default: the
    /// optional entries' absence shows as untraceable symptoms (boxes for
    /// glyphs, silent audio).
    static var installsEverything: Bool {
        get { Preferences.shared.object(forKey: everythingKey) as? Bool ?? true }
        set { Preferences.shared.set(newValue, forKey: everythingKey) }
    }

    private static let everythingKey = "installAllDependencies"

    /// What provisioning installs, in catalog order.
    /// What the optional entries download together, in megabytes, summed
    /// from the sizes the catalog states.
    static var optionalDownloadMegabytes: Int {
        catalog.filter { !$0.required }.reduce(0) { sum, dependency in
            sum + (Int(dependency.download.prefix(while: \.isNumber)) ?? 0)
        }
    }

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
    /// Inside the bottle, so installers see it at a `C:` path.
    private static var scratchRoot: URL { driveC.appendingPathComponent("windows/temp/sevo-deps") }
    private static let scratchRootWindowsPath = #"C:\windows\temp\sevo-deps"#

    /// One install's own directory under the scratch root, in both the paths
    /// it is addressed by. Never share one between installs: the first to
    /// finish deletes it out from under the others' downloads and extractions.
    ///
    /// `root` is the bottle's scratch directory; tests give it one of their
    /// own.
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

    /// A DLL that exists and is not Wine's stand-in, which is stamped
    /// "Wine placeholder DLL" (CrossOver) or "Wine builtin DLL" near the DOS
    /// header.
    private static func hasRealDLL(_ name: String) -> Bool {
        let url = system32.appendingPathComponent(name)
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 0x200), !data.isEmpty else { return false }
        let markers = ["Wine placeholder DLL", "Wine builtin DLL"]
        return !markers.contains { data.range(of: Data($0.utf8)) != nil }
    }

    // MARK: - Install

    /// Installs one catalog entry, narrating through `phase`; answers a
    /// failure description or `nil`. Installs run one at a time, first come
    /// first served: they share one registry, and the hosts rate-limit bursts.
    static func install(
        _ id: String, phase: @escaping @Sendable (String) -> Void,
    ) async -> String? {
        await InstallQueue.shared.enqueue {
            await perform(id, phase: phase)
        } waiting: {
            phase(InterfaceCopy.localized("waiting for the other install to finish"))
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
            default: return String(localized: "unknown dependency \(id)")
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

        /// Runs `body` after everything queued; `waiting` is called when it
        /// cannot start at once.
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

    /// The eleven classic font archives from winetricks' mirror, unpacked by
    /// macOS's `tar` and copied into Fonts, where Wine registers them. Never
    /// run their own extractor into one folder: from the second archive on
    /// `fontinst.exe` stops at an "Overwrite file" prompt `/Q` does not answer.
    private static func installCoreFonts(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        // Microsoft's 2002 archives, as the mirror holds them at one commit.
        let archives = [
            ("andale32.exe", "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970"),
            ("arial32.exe", "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6"),
            ("arialb32.exe", "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8"),
            ("comic32.exe", "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e"),
            ("courie32.exe", "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384"),
            ("georgi32.exe", "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301"),
            ("impact32.exe", "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb"),
            ("times32.exe", "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab"),
            ("trebuc32.exe", "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9"),
            ("verdan32.exe", "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96"),
            ("webdin32.exe", "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a"),
        ]
        let extracted = scratch.directory("fonts")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        for (index, (archive, digest)) in archives.enumerated() {
            phase(String(localized: "downloading fonts (\(index + 1) of \(archives.count))"))
            let file = try await download(
                "https://github.com/pushcx/corefonts/raw/8f8627b0004b5f1b952c09cf6390e4ae46475e59/\(archive)",
                as: archive, into: scratch, sha256: digest,
            )
            let result = await Subprocess.run(
                "/usr/bin/tar", ["-xf", file.path, "-C", extracted.path],
                capture: .combined, timeout: .seconds(60),
            )
            guard result.status == 0 else {
                let reason = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
                throw InstallFailure(message: reason.isEmpty
                    ? String(localized: "\(archive) did not extract")
                    : String(localized: "\(archive) did not extract: \(reason)"))
            }
        }
        phase(InterfaceCopy.localized("installing fonts"))
        try copyFonts(from: extracted, matching: ["ttf", "ttc"])
    }

    /// Microsoft's 14.x redistributable, both architectures, then the
    /// 140-family overrides so the installed files win over Wine's builtins.
    private static func installVCRedist(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        for arch in ["x64", "x86"] {
            phase(String(localized: "downloading VC++ (\(arch))"))
            let installer = try await download(
                "https://aka.ms/vs/17/release/vc_redist.\(arch).exe",
                as: "vc_redist.\(arch).exe", into: scratch,
            )
            phase(String(localized: "installing VC++ (\(arch))"))
            let result = await ClientLifecycle.runSupervisedInBottle([
                SteamBottle.windowsPath(for: installer),
                "/install", "/quiet", "/norestart",
            ])
            // 1638: a newer version is installed. 3010: success, reboot wanted.
            guard let status = result.status, [0, 1638, 3010].contains(Int(status)) else {
                let status = result.status.map(String.init) ?? InterfaceCopy.localized("no exit")
                throw InstallFailure(message: String(localized: "vc_redist.\(arch).exe failed (\(status))"))
            }
        }
        phase(InterfaceCopy.localized("setting DLL overrides"))
        let family = [
            "concrt140", "msvcp140", "msvcp140_1", "msvcp140_2",
            "msvcp140_atomic_wait", "msvcp140_codecvt_ids", "vcamp140",
            "vccorlib140", "vcomp140", "vcruntime140", "vcruntime140_1",
        ]
        try await importOverrides(family.map { ($0, "native,builtin") }, scratch: scratch)
    }

    /// The two fxc2 builds of d3dcompiler_47, copied over Wine's stand-ins so
    /// no override is needed. Pinned to a commit and a digest, since they
    /// replace a system DLL.
    private static func installD3DCompiler(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        phase(InterfaceCopy.localized("downloading d3dcompiler_47"))
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
        phase(InterfaceCopy.localized("installing d3dcompiler_47"))
        try replaceFile(at: system32.appendingPathComponent("d3dcompiler_47.dll"), with: x64)
        try replaceFile(at: syswow64.appendingPathComponent("d3dcompiler_47.dll"), with: x86)
    }

    /// The June 2010 DirectX redistributable: d3dx9, XAudio, XACT and
    /// X3DAudio for both architectures.
    private static func installDirectX2010(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        phase(InterfaceCopy.localized("downloading DirectX redistributable"))
        let redist = try await download(
            "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/directx_Jun2010_redist.exe",
            as: "directx_Jun2010_redist.exe", into: scratch,
            sha256: "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b",
        )
        phase(InterfaceCopy.localized("extracting"))
        let extract = await ClientLifecycle.runSupervisedInBottle([
            SteamBottle.windowsPath(for: redist),
            "/Q", "/T:\(scratch.windowsPath("dx"))",
        ], timeout: .seconds(300))
        guard extract.status == 0 else {
            throw InstallFailure(message: InterfaceCopy.localized("the redistributable refused to extract"))
        }
        phase(InterfaceCopy.localized("running DXSETUP"))
        let setup = await ClientLifecycle.runSupervisedInBottle([
            scratch.windowsPath(#"dx\DXSETUP.exe"#), "/silent",
        ], timeout: .seconds(900))
        guard setup.status == 0 else {
            let status = setup.status.map(String.init) ?? InterfaceCopy.localized("no exit")
            throw InstallFailure(message: String(localized: "DXSETUP failed (\(status))"))
        }
    }

    /// Source Han Sans, four regions, from Adobe's pinned release.
    private static func installCJKFonts(
        scratch: Scratch, phase: @Sendable (String) -> Void,
    ) async throws {
        let regions = [
            ("J", "747734b49301784fed68440711a106de42714d3a7dbc79064a30bbb0cac3f986"),
            ("SC", "2105cdb5a73a7d63fdfe8311312ad7f5c4d166e3c369a9cf737a35c90dee13a2"),
            ("TC", "e075d87d245c4a195e46d0f52fe050efc22e48c8f0f286863f77f03265bb7e9e"),
            ("K", "5390443fb4fee71af369858d99d3fb78e67bf661194f91a776fb2b5713ab8f44"),
        ]
        for (index, (region, digest)) in regions.enumerated() {
            phase(String(localized: "downloading fonts (\(index + 1) of \(regions.count))"))
            let zip = try await download(
                "https://github.com/adobe-fonts/source-han-sans/releases/download/2.004R/SourceHanSans\(region).zip",
                as: "SourceHanSans\(region).zip", into: scratch, sha256: digest,
            )
            phase(String(localized: "installing fonts (\(index + 1) of \(regions.count))"))
            let result = await Subprocess.run(
                "/usr/bin/unzip",
                ["-jo", zip.path, "*.otf", "-d", fontsDirectory.path],
                capture: .combined, timeout: .seconds(300),
            )
            guard result.status == 0 else {
                throw InstallFailure(message: String(localized: "SourceHanSans\(region).zip refused to unzip"))
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

    /// The load-order modes Wine accepts.
    static let overrideModes = ["native,builtin", "native", "builtin", "disabled"]

    /// The bottle's global overrides from `user.reg`, which lags wineserver's
    /// registry by a few seconds after a write.
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

    /// The fxc2 commit's raw content URL prefix.
    private static let fxc2Revision =
        "https://raw.githubusercontent.com/mozilla/fxc2/9aba9b11079303d5577e0e3eb455f4d00f3b5946"

    /// How long a download waits after the first refusal and after the
    /// second, so three attempts in all. Both hosts rate-limit a burst, which
    /// is what pressing every Install button makes.
    static let downloadBackoff: [Duration] = [.seconds(2), .seconds(8)]

    /// Fetches one file into `scratch`, retrying a rate-limiting or briefly
    /// broken host. A file not matching `sha256` (lowercase hex) is refused.
    static func download(
        _ url: String, as name: String, into scratch: Scratch, sha256: String? = nil,
        session: URLSession = .shared, backoff: [Duration] = downloadBackoff,
    ) async throws -> URL {
        guard let source = URL(string: url) else {
            throw InstallFailure(message: String(localized: "bad URL \(url)"))
        }
        var lastFailure = InstallFailure(message: String(localized: "\(name): no attempt was made"))
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

    /// A 429, a 5xx, or a failed transfer.
    private struct RetryableDownload: Error {
        let message: String
    }

    private static func fetch(
        _ source: URL, as name: String, into scratch: Scratch, sha256: String?,
        session: URLSession,
    ) async throws -> URL {
        try FileManager.default.createDirectory(
            at: scratch.url, withIntermediateDirectories: true,
        )
        let temp: URL
        let response: URLResponse
        do {
            (temp, response) = try await session.download(from: source)
        } catch {
            throw RetryableDownload(message: String(localized: "\(name): \(error.localizedDescription)"))
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            let message = String(localized: "\(name): HTTP \(http.statusCode)")
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
                    message: String(localized: "\(name): the download is not the file it should be (sha256 \(digest))"),
                )
            }
        }
        // Again before the move, which is where a missing directory fails.
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
            throw InstallFailure(message: InterfaceCopy.localized("no font files came out of the archives"))
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

    /// One `regedit /S` import for a batch of overrides.
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
            throw InstallFailure(message: InterfaceCopy.localized("regedit refused the overrides import"))
        }
    }
}
