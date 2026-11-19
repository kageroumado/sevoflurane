import Foundation

/// The native side of an NW.js game: the wrapper package NW.js starts with, the browsing data
/// shared with the bottle, and the environment the dock shim reads to exec macOS NW.js in place of
/// the wine process. Steam still launches the Windows exe and owns the process, so playtime, the
/// overlay and the cloud follow it.
nonisolated enum NWJSRunner {
    /// Where the runner's decisions are narrated: stderr for `sevo`, the event log in the app.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    /// One directory per game holding the generated `package.json`, which NW.js takes as its
    /// argument, so the game's own package file is never touched.
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("NWJS")

    static func wrapperDirectory(appID: Int) -> URL {
        root.appendingPathComponent(String(appID))
    }

    static var hasWrappers: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .contains { Int($0) != nil }
    }

    /// One directory per app id for a game's app bundle, outside its wrapper.
    static func bundleDirectory(appID: Int) -> URL {
        root.appendingPathComponent("bundles/\(appID)")
    }

    // MARK: - The environment the shim reads

    /// The keys the dock shim reads from `<prefix>/.sevo/apps/<exe>.env`, or `nil` (no runtime, or
    /// no wrapper), and the game then launches under wine.
    static func environment(
        appID: Int, info: NWJSInfo, runtimeVersion: String?, prefix: URL,
    ) -> [String: String]? {
        guard let runtime = NWJSRuntime.installedRuntime(
            recorded: runtimeVersion, gameVersion: info.version,
        ) else {
            log("nwjs: app \(appID) asks for the native runner, but the NW.js "
                + "\(runtimeVersion ?? info.version) runtime is not installed")
            return nil
        }
        // Browsing data is shared only within one NW.js series: the game's own build refuses a
        // profile a newer Chromium wrote ("your profile can not be used because it is from a newer
        // version"), which would break the wine path. RPG Maker's saves are files in the game
        // directory, shared either way.
        let sameSeries = NWJSRuntime.series(of: runtimeVersion ?? info.version)
            == NWJSRuntime.series(of: info.version)
        guard let wrapper = writeWrapper(
            appID: appID, info: info, sharesBrowsingData: sameSeries,
        ) else { return nil }
        if sameSeries {
            linkDataDirectory(info, prefix: prefix)
        }
        // The game's own bundle, so the Dock tile carries the game; else the runtime's binary,
        // shown as NW.js.
        let executable = writeAppBundle(
            appID: appID, title: title(appID: appID, info: info), runtime: runtime, in: wrapper,
        ) ?? runtime
        var environment = [
            "SEVO_RUNNER": "nwjs",
            "SEVO_NWJS": executable.path,
            "SEVO_NWJS_DIR": wrapper.path,
        ]
        if info.greenworks {
            environment["SEVO_STEAM_STUB"] = "1"
            environment["SEVO_STEAM_APPID"] = String(appID)
            environment["SEVO_STEAM_STUB_PORT"] = String(steamStubPort(appID: appID))
            // A Windows path: the stub searches it and four levels below for the game's
            // `steam_api.dll`.
            environment["SEVO_STEAM_STUB_DIR"] = SteamBottle.windowsPath(
                for: URL(fileURLWithPath: info.dir),
            )
        }
        return environment
    }

    /// The loopback port a game's stub serves achievements on, told to both halves through the env
    /// file.
    ///
    /// Per game, because a stub's Steamworks connection is initialized for one app and an unlock
    /// through another game's stub credits the wrong game. The range clears the Steam client's
    /// ports (27015–27050, 27036/27037). Ids a thousand apart collide; the greenworks side then
    /// sees the wrong app id in the stub's init reply and closes the channel.
    static func steamStubPort(appID: Int) -> Int {
        27060 + abs(appID) % 1000
    }

    // MARK: - The wrapper package

    /// The game's directory inside the wrapper, a symlink. NW.js serves an application from one
    /// root as a `chrome-extension://` origin, and an absolute `file://` main puts up no window
    /// (measured on 0.29.4 and 0.60), so `main` is a relative path through this link.
    private static let gameLink = "game"

    /// Writes `<wrapper>/package.json` (the game's window, name and Chromium switches, `main`
    /// inside the wrapper) and the game link; answers the directory to hand NW.js.
    @discardableResult
    static func writeWrapper(
        appID: Int, info: NWJSInfo, sharesBrowsingData: Bool = true,
    ) -> URL? {
        let directory = wrapperDirectory(appID: appID)
        let gameDirectory = URL(fileURLWithPath: info.dir)
        let manager = FileManager.default
        guard let page = relativePage(of: info) else {
            log("nwjs: app \(appID)'s page \(info.main) is not inside \(info.dir)")
            return nil
        }
        let original = (try? Data(contentsOf: gameDirectory.appendingPathComponent("package.json")))
            .flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any] ?? [:]

        // NW.js names its browsing-data directory after the package, so a run on another series
        // gets its own name. Never use `--user-data-dir` in `chromium-args` for this: NW.js
        // resolves it before reading the package (measured).
        var package: [String: Any] = [
            "name": sharesBrowsingData ? info.packageName : "sevoflurane-\(appID)",
            "main": "\(gameLink)/\(page)",
        ]
        for key in ["js-flags", "chromium-args", "user-agent"] {
            if let value = original[key] { package[key] = value }
        }

        if var window = original["window"] as? [String: Any] {
            // The icon path is relative to the game's package, one level down here.
            if let icon = window["icon"] as? String {
                window["icon"] = "\(gameLink)/\(icon)"
            }
            // NW.js honors an empty title (RPG Maker writes one) and leaves the window untitled;
            // dropped, the page's `<title>` names it.
            if (window["title"] as? String)?.isEmpty == true { window["title"] = nil }
            package["window"] = window
        }

        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try link(gameDirectory, at: directory.appendingPathComponent(gameLink))
            if info.greenworks, writeNodeMain(in: directory, page: page) != nil {
                package["node-main"] = nodeMain
            } else {
                removeNodeMain(in: directory)
            }
            let data = try JSONSerialization.data(
                withJSONObject: package, options: [.prettyPrinted, .sortedKeys],
            )
            let file = directory.appendingPathComponent("package.json")
            if (try? Data(contentsOf: file)) != data {
                try data.write(to: file, options: .atomic)
            }
        } catch {
            log("nwjs: could not write the wrapper package for app \(appID): "
                + error.localizedDescription)
            return nil
        }
        return directory
    }

    /// The game's page relative to its package root.
    private static func relativePage(of info: NWJSInfo) -> String? {
        let root = info.dir.hasSuffix("/") ? info.dir : info.dir + "/"
        guard info.main.hasPrefix(root) else { return nil }
        return String(info.main.dropFirst(root.count))
    }

    private static func link(_ destination: URL, at link: URL) throws {
        let manager = FileManager.default
        if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
            if existing == destination.path { return }
            try manager.removeItem(at: link)
        }
        try manager.createSymbolicLink(at: link, withDestinationURL: destination)
    }

    /// The greenworks preload and its shim, copied together into the wrapper: they find each other
    /// by `__dirname`.
    private static let nodeResources = ["preload.js", "greenworks.js"]

    /// The node-side entry point, written for a game that bundles greenworks when the preload is
    /// available to copy; `nil` otherwise, and the wrapper has no `node-main`.
    ///
    /// A separate file because NW.js makes `node-main` the process's main module, and RPG Maker
    /// reads its save directory from that path (`path.dirname(process.mainModule.filename) +
    /// '/save/'`, `rpg_managers.js:755`); the file points it back at the game's page.
    private static func writeNodeMain(in directory: URL, page: String) -> URL? {
        let manager = FileManager.default
        for name in nodeResources {
            guard let source = BundledResources.url(name) else { return nil }
            let destination = directory.appendingPathComponent(name)
            guard !manager.contentsEqual(atPath: source.path, andPath: destination.path)
            else { continue }
            try? manager.removeItem(at: destination)
            guard (try? manager.copyItem(at: source, to: destination)) != nil else { return nil }
        }
        let pagePath = directory.appendingPathComponent("\(gameLink)/\(page)").path
        let source = """
        // Written by Sevoflurane; edits are overwritten.
        // The preload comes first: a relative require resolves against this
        // file, and the line below moves where this file claims to be.
        require(\(quoted("./\(nodeResources[0])")));
        // NW.js makes this file the process's main module, and RPG Maker
        // derives its save directory from the main module's path, so the
        // game's own page goes back before anything reads it.
        process.mainModule.filename = \(quoted(pagePath));
        
        """
        let file = directory.appendingPathComponent(nodeMain)
        let data = Data(source.utf8)
        if (try? Data(contentsOf: file)) != data {
            try? data.write(to: file, options: .atomic)
        }
        return file
    }

    private static func removeNodeMain(in directory: URL) {
        for name in nodeResources + [nodeMain] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// The wrapper's node entry, a name NW.js resolves inside the application.
    private static let nodeMain = "node-main.js"

    /// A path as a JavaScript string literal, with JSON's escaped slashes unescaped.
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: #"\/"#, with: "/")
    }

    /// Removes the wrappers and bundles of every app id outside `wanted`.
    static func removeWrappers(keeping wanted: Set<Int>) {
        let manager = FileManager.default
        for directory in [root, root.appendingPathComponent("bundles")] {
            for entry in (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
            )) ?? [] {
                guard let appID = Int(entry.lastPathComponent),
                      !wanted.contains(appID) else { continue }
                try? manager.removeItem(at: entry)
            }
        }
    }

    // MARK: - The game's own app bundle

    /// A native run's title: Steam's name for the game, else its window title, else the app id.
    static func title(appID: Int, info: NWJSInfo?) -> String {
        if let name = GameConfig.game(appID).name, !name.isEmpty { return name }
        if let info, let package = (try? Data(contentsOf: URL(fileURLWithPath: info.dir)
                .appendingPathComponent("package.json")))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
            let window = package["window"] as? [String: Any],
            let title = window["title"] as? String, !title.isEmpty { return title }
        return "App \(appID)"
    }

    /// A title as a file name: only `/` and `:` are replaced, since the Dock shows it.
    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }

    /// Builds the bundle a native run is exec'd through, beside the wrapper, and answers its
    /// executable.
    ///
    /// macOS names and icons a Dock tile after the running executable's bundle, so a game run from
    /// the runtime shows "nwjs". Each game's bundle links the runtime's `Contents` entry by entry:
    /// dyld resolves `@executable_path` from the launch path, so the symlinked binary finds the
    /// framework and helpers through our `Contents`.
    @discardableResult
    static func writeAppBundle(
        appID: Int, title: String, runtime: URL, in _: URL,
    ) -> URL? {
        let manager = FileManager.default
        let source = runtime.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceContents = source.appendingPathComponent("Contents")
        guard manager.fileExists(atPath: sourceContents.path) else { return nil }

        let stem = fileSafe(title)
        guard !stem.isEmpty else { return nil }
        // Never inside the wrapper: NW.js 0.60 and later opens no window for an application root
        // holding a bundle (measured). The Dock labels a tile with the bundle's file name whatever
        // `CFBundleName` says (measured), so the bundle is named after the game, in a directory per
        // app id.
        let bundles = bundleDirectory(appID: appID)
        let bundle = bundles.appendingPathComponent("\(stem).app")
        try? manager.createDirectory(at: bundles, withIntermediateDirectories: true)
        // A renamed game leaves its old bundle behind.
        for entry in (try? manager.contentsOfDirectory(at: bundles, includingPropertiesForKeys: nil))
            ?? [] where entry.lastPathComponent != bundle.lastPathComponent {
            try? manager.removeItem(at: entry)
        }

        let contents = bundle.appendingPathComponent("Contents")
        let ownEntries: Set = ["MacOS", "Resources", "Info.plist", "PkgInfo"]
        do {
            try manager.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true,
            )
            try manager.createDirectory(
                at: contents.appendingPathComponent("Resources"), withIntermediateDirectories: true,
            )
            // The framework (under `Versions` or `Frameworks`, by build age) and the rest; the code
            // signature stays behind, since it covers the runtime's Info.plist.
            for entry in try manager.contentsOfDirectory(
                at: sourceContents, includingPropertiesForKeys: nil,
            ) where !ownEntries.contains(entry.lastPathComponent)
                && entry.lastPathComponent != "_CodeSignature" {
                try link(entry, at: contents.appendingPathComponent(entry.lastPathComponent))
            }
            try link(runtime, at: contents.appendingPathComponent("MacOS/\(stem)"))
            try writeResources(
                from: sourceContents.appendingPathComponent("Resources"),
                to: contents.appendingPathComponent("Resources"),
                icon: GameIcon.icns(appID: appID, title: title),
            )
            try writePlist(
                from: sourceContents.appendingPathComponent("Info.plist"),
                to: contents.appendingPathComponent("Info.plist"),
                title: title, stem: stem,
                hasIcon: manager.fileExists(
                    atPath: contents.appendingPathComponent("Resources/\(iconName).icns").path,
                ),
            )
            let pkgInfo = contents.appendingPathComponent("PkgInfo")
            let stamp = Data("APPL????".utf8)
            if (try? Data(contentsOf: pkgInfo)) != stamp { try stamp.write(to: pkgInfo) }
        } catch {
            log("nwjs: could not build the app bundle for app \(appID): "
                + error.localizedDescription)
            return nil
        }
        return contents.appendingPathComponent("MacOS/\(stem)")
    }

    /// Links the runtime's resources, which Chromium reads by name, beside our icon. The `.lproj`
    /// directories are left out: their `InfoPlist.strings` name the app "nwjs", and a localized
    /// name beats `Info.plist`.
    private static func writeResources(from source: URL, to destination: URL, icon: URL?) throws {
        let manager = FileManager.default
        let ours = "\(iconName).icns"
        var wanted: Set<String> = []
        for entry in (try? manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil,
        )) ?? [] {
            let name = entry.lastPathComponent
            if entry.pathExtension == "lproj" { continue }
            // Our icon, when there is one, replaces the runtime's `app.icns`.
            if name == ours, icon != nil { continue }
            wanted.insert(name)
            try link(entry, at: destination.appendingPathComponent(name))
        }
        let target = destination.appendingPathComponent(ours)
        if let icon {
            wanted.insert(ours)
            if !manager.contentsEqual(atPath: icon.path, andPath: target.path) {
                try? manager.removeItem(at: target)
                try manager.copyItem(at: icon, to: target)
            }
        }
        for entry in (try? manager.contentsOfDirectory(
            at: destination, includingPropertiesForKeys: nil,
        )) ?? [] where !wanted.contains(entry.lastPathComponent) {
            try? manager.removeItem(at: entry)
        }
    }

    private static let iconName = "app"

    /// The runtime's plist with the game's identity written over it.
    private static func writePlist(
        from source: URL, to destination: URL,
        title: String, stem: String, hasIcon: Bool,
    ) throws {
        guard let data = try? Data(contentsOf: source),
              var plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil,
              ) as? [String: Any]
        else { throw BundleError("the NW.js runtime has no readable Info.plist") }
        plist["CFBundleName"] = title
        plist["CFBundleDisplayName"] = title
        plist["CFBundleExecutable"] = stem
        // Never change the bundle identifier: Chromium derives its renderers' Mach service name
        // from it, and the framework's helper carries the runtime's, so ours gives
        // `bootstrap_look_up: Unknown service name` and no window (measured on 0.29.4).
        // `CFBundleIconName` would point at an asset-catalog icon this bundle lacks.
        plist["CFBundleIconName"] = nil
        plist["CFBundleIconFile"] = hasIcon ? iconName : nil
        let written = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0,
        )
        if (try? Data(contentsOf: destination)) != written {
            try written.write(to: destination, options: .atomic)
        }
    }

    private struct BundleError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    // MARK: - Stopping a native run

    /// One game's native processes: every NW.js process carries the wrapper path on its command
    /// line, and the one whose parent is not among them is the browser. Matched by path and descent
    /// because helper binaries sit in different places across NW.js versions.
    static func runningProcesses(appID: Int) -> (browser: [pid_t], helpers: [pid_t]) {
        let directory = wrapperDirectory(appID: appID).path
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-axo", "pid=,ppid=,command="]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return ([], []) }
        let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
        process.waitUntilExit()
        return processes(inPS: String(decoding: data, as: UTF8.self), directory: directory)
    }

    /// The browser and helpers among `ps -axo pid=,ppid=,command=` lines naming `directory` as a
    /// whole path (followed by `/`, a space or the line's end), so app 400's wrapper does not match
    /// app 4000's.
    static func processes(inPS output: String, directory: String) -> (browser: [pid_t], helpers: [pid_t]) {
        var parents: [pid_t: pid_t] = [:]
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = pid_t(fields[0]), let parent = pid_t(fields[1]),
                  names(directory, in: fields[2]) else { continue }
            parents[pid] = parent
        }
        let matched = Set(parents.keys)
        let browser = parents.filter { !matched.contains($0.value) }.map(\.key)
        return (browser.sorted(), matched.subtracting(browser).sorted())
    }

    private static func names(_ directory: String, in command: Substring) -> Bool {
        var remainder = command[...]
        while let found = remainder.range(of: directory) {
            let next = remainder[found.upperBound...].first
            if next == nil || next == "/" || next == " " { return true }
            remainder = remainder[found.upperBound...]
        }
        return false
    }

    /// Ends a native run with `SIGTERM`, since Steam's terminate reaches only into the bottle. Only
    /// the browser is signaled when there is one: killing renderers directly leaves orphans holding
    /// the profile.
    @discardableResult
    static func terminate(appID: Int) -> [pid_t] {
        let running = runningProcesses(appID: appID)
        let targets = running.browser.isEmpty ? running.helpers : running.browser
        for pid in targets { kill(pid, SIGTERM) }
        return targets
    }

    // MARK: - Browsing data

    /// Points the macOS browsing-data directory at the bottle's, so localStorage and IndexedDB (RPG
    /// Maker's options, some plugins' state) survive a switch. A real directory already there is
    /// left alone.
    static func linkDataDirectory(_ info: NWJSInfo, prefix: URL) {
        let manager = FileManager.default
        let bottleSide = prefix
            .appendingPathComponent("drive_c/users/\(SteamBottle.windowsUser)")
            .appendingPathComponent("AppData/Local/\(info.packageName)/User Data")
        let macOSSide = UserHome.url
            .appendingPathComponent("Library/Application Support/\(info.packageName)")

        if let existing = try? manager.destinationOfSymbolicLink(atPath: macOSSide.path) {
            if URL(fileURLWithPath: existing).standardizedFileURL == bottleSide.standardizedFileURL {
                return
            }
            // A link into a bottle is ours and is repointed; any other link is left alone.
            guard existing.hasPrefix(Engine.managedBottlesRoot.path)
                || existing.hasPrefix(SteamBottle.bottlesRoot.path)
            else {
                log("nwjs: \(macOSSide.path) already points at \(existing) — leaving it alone")
                return
            }
            try? manager.removeItem(at: macOSSide)
        } else if manager.fileExists(atPath: macOSSide.path) {
            log("nwjs: \(macOSSide.path) is a real directory — the native run keeps its own "
                + "browsing data, separate from the bottle's")
            return
        }

        do {
            try manager.createDirectory(at: bottleSide, withIntermediateDirectories: true)
            try manager.createDirectory(
                at: macOSSide.deletingLastPathComponent(), withIntermediateDirectories: true,
            )
            try manager.createSymbolicLink(at: macOSSide, withDestinationURL: bottleSide)
        } catch {
            log("nwjs: could not share the browsing data directory: \(error.localizedDescription)")
        }
    }
}
