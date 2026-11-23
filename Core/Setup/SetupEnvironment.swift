import Foundation
import ServiceManagement

/// The machine-touching half of provisioning, split from ``Provisioner`` so
/// the DEBUG onboarding harness (`SetupDryRun.swift`) can simulate effects.
@MainActor
protocol SetupEnvironment: AnyObject {
    /// Whether effects are simulated (the dry-run harness).
    var isSimulation: Bool { get }

    /// The bottle every stage addresses: the stored choice on a live run, the
    /// fixture's own bottle in a dry run.
    var bottleName: String { get }

    /// Names the bottle the remaining stages address.
    func chooseBottle(named name: String)

    /// Where the engine keeps its bottles; detection's bottle records are
    /// matched against it, so both must describe the same machine.
    var bottlesRoot: URL { get }

    /// Whether the engine choice asks for the built-in engine, which the
    /// engine stage then installs even where CrossOver is usable.
    var wantsManagedEngine: Bool { get }

    /// Re-reads the machine facts every stage decision runs on.
    func detect() async -> SetupDetection

    /// `softwareupdate --install-rosetta --agree-to-license`.
    func installRosetta() async -> SetupCommandOutcome

    /// Installs the managed engine from `tarball`, else the signed copy
    /// shipped with the app, else the manifest's release. The outcome's output
    /// is the version installed; the fraction is download progress or `nil`.
    func installEngine(
        from tarball: URL?,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome

    /// `cxbottle --create --template win10_64` under CrossOver; a
    /// `wineboot -u`-initialized prefix under a managed engine.
    func createBottle(named name: String) async -> SetupCommandOutcome

    /// Fetches SteamSetup.exe from the Steam CDN into the bottle's `drive_c`.
    func downloadSteamInstaller(intoBottle name: String) async throws

    /// Waits for a fresh prefix to finish booting: an installer started while
    /// `wineboot` still writes the registry exits nonzero with no reason.
    func settleBottle(named name: String) async

    /// Runs `SteamSetup.exe /S` with Wine's error channel on.
    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome

    /// Marks the bottle as one Steam's installer failed in, so the next pass
    /// rebuilds it.
    func markSteamInstallerFailed(inBottle name: String)

    /// Whether Steam's installer failed in the bottle and setup made it, so
    /// it may be built again.
    func steamInstallerFailed(inBottle name: String) -> Bool

    /// Whether the bottle's 32-bit system DLLs are in place. Neither
    /// `wineboot -u`'s exit status nor `system.reg` says so, and a bottle
    /// without them fails every 32-bit program with `could not load
    /// kernel32.dll`.
    func bottleIsComplete(named name: String) -> Bool

    /// Ends the bottle's processes and renames it `<name>.broken-<time>`,
    /// which detection skips; answers the new name.
    func setAsideBottle(named name: String) async throws -> String

    /// Bootstrapper → full client, the long headless download. The updater's
    /// exit code is unreliable, so the caller judges by what landed on disk.
    func updateSteamClient(inBottle name: String) async

    /// The idempotent per-bottle registry values (tray, SDL bus, GPU) and
    /// graphics files.
    func configureBottle(named name: String) async

    /// Ends every Wine process in the bottle (`wineserver -k`).
    func endWineProcesses(inBottle name: String) async

    /// Whether the active bottle contains the dependency's installed payload.
    func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool

    /// Installs a required game runtime in the active bottle.
    func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome

    func setOpenAtLogin(_ enabled: Bool) throws
    var openAtLogin: Bool { get }

    // MARK: What the assistant asks, and where its answers are kept

    /// The stored engine choice: the built-in engine, CrossOver, or none yet.
    var storedEngineIsManaged: Bool? { get }

    /// Stores the engine the assistant settled on and makes it the one the
    /// stages address.
    func storeEngineChoice(managed: Bool)

    /// Whether the engine the stages address is the built-in one.
    var usesManagedEngine: Bool { get }

    /// Which engine a bottle lives with: the built-in one, CrossOver, or
    /// (`nil`) a folder setup does not drive.
    func engineIsManaged(ofBottleAt url: URL) -> Bool?

    /// What tells the Steam in a bottle from the others.
    func libraryFacts(ofBottleAt url: URL) async -> SteamLibraryFacts

    /// Whether this Mac can run Apple's D3DMetal at all.
    var runsD3DMetal: Bool { get }

    /// The answer to the sharing question; `nil` until it is given.
    var sharesRunStats: Bool? { get }
    func answerSharing(_ shares: Bool)

    /// Whether an assistant started on this Mac and has not finished. Set
    /// when one opens and cleared by its last page, so a Mac with Steam
    /// installed and nothing stored reads as finished.
    var assistantInProgress: Bool { get set }
}

extension SetupEnvironment {
    var isSimulation: Bool {
        false
    }

    /// The live machine's answers.
    var bottleName: String {
        SteamBottle.name
    }

    func chooseBottle(named name: String) {
        SteamBottle.choose(name)
    }

    var bottlesRoot: URL {
        Engine.active.bottlesRoot
    }

    var wantsManagedEngine: Bool {
        Engine.preferenceWantsManaged
    }

    var storedEngineIsManaged: Bool? {
        Engine.storedChoiceIsManaged
    }

    func storeEngineChoice(managed: Bool) {
        Engine.chooseAtSetup(managed: managed)
    }

    var usesManagedEngine: Bool {
        if case .managed = Engine.active { true } else { false }
    }

    func engineIsManaged(ofBottleAt url: URL) -> Bool? {
        let root = url.deletingLastPathComponent().standardizedFileURL.path
        if root == Engine.managedBottlesRoot.standardizedFileURL.path { return true }
        if root == SteamBottle.bottlesRoot.standardizedFileURL.path { return false }
        return nil
    }

    @concurrent
    nonisolated func libraryFacts(ofBottleAt url: URL) async -> SteamLibraryFacts {
        SteamLibraryFacts.read(steamRoot: SteamBottle.steamRoot(inBottle: url))
    }

    var runsD3DMetal: Bool {
        MacHardware.isAppleSilicon
    }

    var sharesRunStats: Bool? {
        Preferences.sharesRunStats
    }

    func answerSharing(_ shares: Bool) {
        Preferences.sharesRunStats = shares
    }

    /// Nothing boots in a simulation, so nothing has to settle.
    func settleBottle(named _: String) async {}
}

nonisolated struct SetupCommandOutcome: Sendable {
    let status: Int32?
    /// What the command printed; for a failure the app words itself, the
    /// cause as a sentence.
    let output: String
    /// What to do about a failure, where the failure says.
    var advice: String?

    var succeeded: Bool {
        status == 0
    }

    static func success(_ output: String = "") -> Self {
        .init(status: 0, output: output)
    }

    static func failure(_ output: String, advice: String? = nil) -> Self {
        .init(status: 1, output: output, advice: advice)
    }
}

/// The real executor.
@MainActor
final class LiveSetupEnvironment: SetupEnvironment {
    private static let steamSetupURL =
        URL(string: "https://cdn.fastly.steamstatic.com/client/installer/SteamSetup.exe")!

    func detect() async -> SetupDetection {
        await SetupProbe.detect()
    }

    func installRosetta() async -> SetupCommandOutcome {
        await run(
            "/usr/sbin/softwareupdate",
            ["--install-rosetta", "--agree-to-license"],
            timeout: .seconds(600),
        )
    }

    func installEngine(
        from tarball: URL?,
        progress: @escaping @Sendable (String, Double?) -> Void,
    ) async -> SetupCommandOutcome {
        do {
            if let tarball {
                SetupLog.log("engine install from \(tarball.path)")
                let version = try await EngineInstaller.install(from: tarball, progress: progress)
                return .success(version)
            }
            if let bundled = EngineInstaller.bundledTarball() {
                SetupLog.log("engine install from the copy shipped with the app: \(bundled.path)")
                let version = try await EngineInstaller.install(
                    from: bundled, requiringSignature: true, progress: progress,
                )
                return .success(version)
            }
            let release = try await EngineInstaller.latestRelease()
            try await EngineInstaller.install(release, progress: progress)
            return .success(release.version)
        } catch {
            SetupLog.log("engine install failed: \(error)")
            return .failure(SetupFailureText.sentence(error), advice: SetupFailureText.advice(error))
        }
    }

    func createBottle(named name: String) async -> SetupCommandOutcome {
        switch Engine.active {
        case .crossover, .crossoverPreview:
            return await run(
                (Engine.active.crossoverBin ?? "") + "/cxbottle",
                [
                    "--bottle",
                    name,
                    "--create",
                    "--template",
                    "win10_64",
                    "--description",
                    Self.crossOverDescription,
                ],
                timeout: .seconds(600),
            )
        case .managed:
            let prefix = Engine.active.bottlesRoot.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: prefix, withIntermediateDirectories: true,
                )
            } catch {
                return .failure("\(error)")
            }
            let boot = await runWine(bottle: name, args: ["wineboot", "-u"])
            guard boot.succeeded else { return boot }
            // A fresh prefix reports a pre-Windows-10 version, which makes
            // Steam install its legacy CEF (`bin/cef/cef.win7x64`); this
            // matches CrossOver's `win10_64` template.
            return await runWine(bottle: name, args: ["winecfg", "/v", "win10"])
        }
    }

    /// Whether a hive file contains `needle`. A text scan suffices: a false
    /// negative costs one redundant `reg add`.
    private nonisolated static func registry(
        of bottle: URL, file: String, contains needle: String,
    ) -> Bool {
        let url = bottle.appendingPathComponent(file)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains(needle)
    }

    func downloadSteamInstaller(intoBottle name: String) async throws {
        let bottleURL = Engine.active.bottlesRoot.appendingPathComponent(name)
        let (temp, response) = try await URLSession.shared.download(from: Self.steamSetupURL)
        // A failed fetch must throw here, as a network error: an error page
        // saved as the installer fails the install, and that rebuilds the bottle.
        // A captive portal answers 200 with HTML, so the PE signature is checked too.
        if let http = response as? HTTPURLResponse, !(200 ..< 300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: temp)
            throw InstallerDownloadFailed(description: String(localized: "Steam's installer could not be downloaded (HTTP \(http.statusCode))"))
        }
        let head = try? FileHandle(forReadingFrom: temp).read(upToCount: 2)
        guard head == Data("MZ".utf8) else {
            try? FileManager.default.removeItem(at: temp)
            throw InstallerDownloadFailed(description: String(localized: "Steam's installer download is not a Windows program; check the network"))
        }
        let setup = bottleURL.appendingPathComponent("drive_c/SteamSetup.exe")
        try? FileManager.default.removeItem(at: setup)
        try FileManager.default.moveItem(at: temp, to: setup)
    }

    struct InstallerDownloadFailed: Error, CustomStringConvertible {
        let description: String
    }

    /// Polls `system.reg` until it stops changing: `wineboot` returns before
    /// its last registry write is done.
    func settleBottle(named name: String) async {
        let registry = Engine.active.bottlesRoot
            .appendingPathComponent(name)
            .appendingPathComponent("system.reg")
        var lastWrite = modificationDate(of: registry)
        var stableSince = Date.now
        for _ in 0 ..< Self.settlePolls {
            try? await Task.sleep(for: .milliseconds(500))
            let write = modificationDate(of: registry)
            if write != lastWrite {
                lastWrite = write
                stableSince = .now
                continue
            }
            if Date.now.timeIntervalSince(stableSince) >= Self.settleQuiet { return }
        }
        SetupLog.log("provision: the prefix is still writing its registry — going ahead")
    }

    /// How long the registry must sit still, and how long to wait for that.
    private static let settleQuiet: TimeInterval = 2
    private static let settlePolls = 60

    private nonisolated func modificationDate(of file: URL) -> Date? {
        (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    func runSteamInstaller(inBottle name: String) async -> SetupCommandOutcome {
        // The user acts on this failure, and under the default
        // `WINEDEBUG=-all` it would carry no reason.
        await runWine(
            bottle: name, args: [#"C:\SteamSetup.exe"#, "/S"],
            wineDebug: "err+all",
        )
    }

    func markSteamInstallerFailed(inBottle name: String) {
        let marker = Self.installerFailureMarker(inBottle: name)
        try? FileManager.default.createDirectory(
            at: marker.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        try? Data().write(to: marker)
    }

    func steamInstallerFailed(inBottle name: String) -> Bool {
        guard Self.setupMade(bottle: name) else { return false }
        return FileManager.default.fileExists(atPath: Self.installerFailureMarker(inBottle: name).path)
    }

    func bottleIsComplete(named name: String) -> Bool {
        guard Self.setupMade(bottle: name) else { return true }
        let kernel32 = Engine.active.bottlesRoot.appendingPathComponent(name)
            .appendingPathComponent("drive_c/windows/syswow64/kernel32.dll")
        return FileManager.default.fileExists(atPath: kernel32.path)
    }

    func setAsideBottle(named name: String) async throws -> String {
        await endWineProcesses(inBottle: name)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let aside = "\(name).broken-\(formatter.string(from: .now))"
        let root = Engine.active.bottlesRoot
        try FileManager.default.moveItem(
            at: root.appendingPathComponent(name), to: root.appendingPathComponent(aside),
        )
        return aside
    }

    /// Whether setup made the bottle and may rebuild it: a managed prefix
    /// always, a CrossOver bottle only with ``crossOverDescription``, since
    /// any other is the person's own.
    private static func setupMade(bottle name: String) -> Bool {
        guard Engine.active.isCrossOver else { return true }
        let conf = Engine.active.bottlesRoot.appendingPathComponent(name)
            .appendingPathComponent("cxbottle.conf")
        guard let text = try? String(contentsOf: conf, encoding: .utf8) else { return false }
        return text.contains("\"Description\" = \"\(crossOverDescription)\"")
    }

    /// The description `cxbottle --create` writes into a bottle setup makes.
    private static let crossOverDescription = "Sevoflurane Steam"

    private static func installerFailureMarker(inBottle name: String) -> URL {
        Engine.active.bottlesRoot.appendingPathComponent(name)
            .appendingPathComponent(".sevo/steam-installer-failed")
    }

    func updateSteamClient(inBottle name: String) async {
        _ = await runWine(
            bottle: name,
            args: [
                SteamBottle.exeWindowsPath,
                "-forcesteamupdate",
                "-forcepackagedownload",
                "-exitsteam",
            ],
            timeout: .seconds(1800),
        )
    }

    func configureBottle(named name: String) async {
        let bottle = Engine.active.bottlesRoot.appendingPathComponent(name)
        for args in await Self.registryWrites(forBottle: bottle) {
            _ = await runWine(bottle: name, args: args)
        }
        await Self.stageBottleFiles(bottle, named: name)
    }

    /// The `wine` invocations the bottle's registry still needs. A value
    /// already in the hive is skipped, because a `reg add` against a booting
    /// client can hang for the whole subprocess timeout.
    @concurrent
    private nonisolated static func registryWrites(forBottle bottle: URL) async -> [[String]] {
        var writes: [[String]] = []
        if !registry(of: bottle, file: "user.reg", contains: #""ShowSystray"="N""#) {
            writes.append([
                "reg", "add", #"HKCU\Software\Wine\Explorer"#,
                "/v", "ShowSystray", "/t", "REG_SZ", "/d", "N", "/f",
            ])
        }
        // Off, Dormison's Mac driver hands Steam's tray icon to explorer's
        // hidden systray instead of a menu-bar status item; other engines
        // ignore the value.
        if !registry(of: bottle, file: "user.reg", contains: #""StatusItems"="N""#) {
            writes.append([
                "reg", "add", #"HKCU\Software\Wine\Mac Driver"#,
                "/v", "StatusItems", "/t", "REG_SZ", "/d", "N", "/f",
            ])
        }
        // `Engine.keepsSDLBus`: on, the SDL bus reaches a Bluetooth Xbox pad;
        // on an older engine it would wake winedevice.exe every millisecond.
        // Written or removed each boot, so a bottle follows its engine.
        let sdlOff = registry(
            of: bottle, file: "system.reg", contains: #""Enable SDL"=dword:00000000"#,
        )
        if Engine.active.keepsSDLBus, sdlOff {
            writes.append([
                "reg", "delete", #"HKLM\System\CurrentControlSet\Services\winebus"#,
                "/v", "Enable SDL", "/f",
            ])
        } else if !Engine.active.keepsSDLBus, !sdlOff {
            writes.append([
                "reg", "add", #"HKLM\System\CurrentControlSet\Services\winebus"#,
                "/v", "Enable SDL", "/t", "REG_DWORD", "/d", "0", "/f",
            ])
        }
        // Wine's own renderer reads the card from the registry, not the
        // environment. This catches a bottle whose picker import never
        // landed, importing the same file the picker does.
        let gpu = BottleGraphics.currentSelection().gpu
        if !BottleGraphics.registryHolds(gpu, inBottle: bottle),
           GPUIdentity.writeWineD3DRegistry(gpu, intoBottle: bottle) != nil {
            writes.append(["regedit", "/S", GPUIdentity.wineD3DRegistryWindowsPath])
        }
        return writes
    }

    /// Writes the GPU default, DXVK's config and a managed engine's renderer
    /// DLLs into the prefix.
    @concurrent
    private nonisolated static func stageBottleFiles(_ bottle: URL, named name: String) async {
        BottleGraphics.adoptDefaultGPU(forBottle: bottle)
        // DXVK reads only this file, never the launch environment.
        GPUIdentity.writeDXVKConfig(BottleGraphics.currentSelection().gpu, intoBottle: bottle)
        guard case let .managed(version) = Engine.active else {
            do {
                try BottleGraphics.reassertDefaults(forBottle: bottle)
            } catch {
                SetupLog.log("graphics defaults not written: \(error)")
            }
            return
        }
        // `n,b` overrides need the renderer DLLs inside the prefix.
        let staged = EngineRenderers.stage(
            BottleGraphics.managedSelection().renderer,
            engine: Engine.managedRoot.appendingPathComponent(version),
            bottle: bottle,
        )
        if !staged.isEmpty {
            SetupLog.log("staged \(staged.count) renderer DLLs into \(name)")
        }
    }

    func setOpenAtLogin(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }

    func isDependencyInstalled(_ dependency: BottleDependencies.Dependency) -> Bool {
        BottleDependencies.isInstalled(dependency)
    }

    func installDependency(_ dependency: BottleDependencies.Dependency) async -> SetupCommandOutcome {
        let failure = await BottleDependencies.install(dependency.id) { phase in
            SetupLog.log("provision: \(dependency.name): \(phase)")
        }
        return failure.map { SetupCommandOutcome.failure($0) } ?? .success()
    }

    var openAtLogin: Bool {
        SMAppService.mainApp.status == .enabled
    }

    var assistantInProgress: Bool {
        get { Preferences.app.bool(forKey: Self.assistantInProgressKey) }
        set { Preferences.app.set(newValue, forKey: Self.assistantInProgressKey) }
    }

    private static let assistantInProgressKey = "setupAssistantInProgress"

    /// Captures stdout and stderr combined, which provisioning quotes in
    /// failure messages.
    private nonisolated func runWine(
        bottle: String, args: [String], timeout: Duration = .seconds(600),
        wineDebug: String? = nil,
    ) async -> SetupCommandOutcome {
        let invocation = Engine.active.wineInvocation(
            bottle: bottle, wait: .children, program: args,
        )
        var environment = invocation.environment
        if let wineDebug {
            // CrossOver's invocation carries no environment of its own.
            var merged = invocation.environment ?? ProcessInfo.processInfo.environment
            merged["WINEDEBUG"] = wineDebug
            environment = merged
        }
        let started = ContinuousClock.now
        let outcome = await run(
            invocation.executable.path,
            invocation.arguments,
            environment: environment,
            timeout: timeout,
        )
        // A timeout kills only the launcher, not the programs it started.
        if ContinuousClock.now - started >= timeout {
            SetupLog.log("provision: wine \(args.first ?? "") timed out — ending the bottle's processes")
            await endWineProcesses(inBottle: bottle)
        }
        return outcome
    }

    nonisolated func endWineProcesses(inBottle name: String) async {
        // wineserver finds its prefix by WINEPREFIX, under CrossOver too.
        let prefix = Engine.active.bottlesRoot.appendingPathComponent(name)
        _ = await Subprocess.run(
            Engine.active.wineserverURL.path, ["-k"],
            environment: ["WINEPREFIX": prefix.path, "PATH": "/usr/bin"],
            capture: .none, timeout: .seconds(15),
        )
    }

    private nonisolated func run(
        _ path: String, _ arguments: [String],
        environment: [String: String]? = nil, timeout: Duration,
    ) async -> SetupCommandOutcome {
        let result = await Subprocess.run(
            path, arguments, environment: environment, capture: .combined, timeout: timeout,
        )
        return SetupCommandOutcome(status: result.status, output: result.output)
    }
}
