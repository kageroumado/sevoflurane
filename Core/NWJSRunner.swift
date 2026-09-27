import Foundation

/// The native side of an NW.js game: the wrapper package NW.js is started
/// with, the browsing-data directory shared with the bottle, and the
/// environment the dock shim reads to exec macOS NW.js in place of the wine
/// process.
///
/// Steam still launches the game's Windows exe and still owns the process, so
/// playtime, the overlay and the cloud all follow it; only the code inside
/// the process changes.
nonisolated enum NWJSRunner {
    /// Where the runner's decisions are narrated. The default reaches `sevo`'s
    /// caller; the app points it at its own event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    /// One directory per game, holding the generated `package.json`. NW.js
    /// takes the directory as its argument and reads the package there, so
    /// the game's own package file is never touched.
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("NWJS")

    static func wrapperDirectory(appID: Int) -> URL {
        root.appendingPathComponent(String(appID))
    }

    /// Whether any game is set up to run natively right now — the cheap
    /// question to ask before the expensive one.
    static var hasWrappers: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .contains { Int($0) != nil }
    }

    /// Where a game's own app bundle lives: one directory per app id, outside
    /// the wrapper the game is served from.
    static func bundleDirectory(appID: Int) -> URL {
        root.appendingPathComponent("bundles/\(appID)")
    }

    // MARK: - The environment the shim reads

    /// The keys the dock shim looks for in `<prefix>/.sevo/apps/<exe>.env`,
    /// or `nil` when the game cannot run natively right now — no runtime for
    /// its NW.js series, or no wrapper to start. The game then launches under
    /// wine, which is the state it was in before the switch.
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
        // The two runners share their browsing data only when they run the
        // same NW.js: a profile written by a newer Chromium is one the game's
        // own build refuses to open at all ("your profile can not be used
        // because it is from a newer version"), which would break the wine
        // path the moment a native run had touched it. RPG Maker's saves are
        // files in the game directory and are shared either way.
        let sameSeries = NWJSRuntime.series(of: runtimeVersion ?? info.version)
            == NWJSRuntime.series(of: info.version)
        guard let wrapper = writeWrapper(
            appID: appID, info: info, sharesBrowsingData: sameSeries,
        ) else { return nil }
        if sameSeries {
            linkDataDirectory(info, prefix: prefix)
        }
        // Exec'd through the game's own bundle when one can be built, so the
        // Dock tile carries the game rather than NW.js; the runtime's own
        // binary otherwise, which runs identically and is only anonymous.
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
            // The stub searches this directory and four levels below it for
            // the game's `steam_api.dll`, which it loads into itself — so it
            // is named the way a Windows program names a directory.
            environment["SEVO_STEAM_STUB_DIR"] = SteamBottle.windowsPath(
                for: URL(fileURLWithPath: info.dir),
            )
        }
        return environment
    }

    /// The loopback port a game's stub serves achievements on and its native
    /// side connects to. Both halves are told the same number through the
    /// same env file, so it only has to be stable and the game's own.
    ///
    /// Per game rather than one for everyone: a stub holds a Steamworks
    /// connection initialized against a single app, so two games running at
    /// once must not land on one another's — an unlock through the wrong stub
    /// would credit the wrong game. The range starts clear of the ports the
    /// Steam client itself binds (27015–27050, and 27036/27037 for its local
    /// services). Two ids a thousand apart still collide; the greenworks side
    /// compares the app id in the stub's init reply against its own and
    /// closes the channel when they disagree, so that case is a game without
    /// achievements rather than a game with someone else's.
    static func steamStubPort(appID: Int) -> Int {
        27060 + abs(appID) % 1000
    }

    // MARK: - The wrapper package

    /// The name the game's own directory takes inside the wrapper.
    ///
    /// NW.js serves an application from one root, as a `chrome-extension://`
    /// origin, and a page outside that root is a network error — an absolute
    /// `file://` main puts up no window at all (measured on 0.29.4 and 0.60).
    /// So the game's directory is a child of the wrapper, by
    /// symlink, and `main` is a relative path through it.
    private static let gameLink = "game"

    /// Writes `<wrapper>/package.json` and the link the game is reached
    /// through: the game's own window, name and Chromium switches, with
    /// `main` naming its page inside the wrapper's root. Answers the
    /// directory to hand NW.js.
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

        // NW.js keeps browsing data in a directory named after the package,
        // and takes that name from here rather than from the command line, so
        // a run on a different NW.js than the game's own is given a name of
        // its own. `--user-data-dir` in `chromium-args` does not do it: the
        // path is resolved before the package is read (measured — the shared
        // directory was still the one written).
        var package: [String: Any] = [
            "name": sharesBrowsingData ? info.packageName : "sevoflurane-\(appID)",
            "main": "\(gameLink)/\(page)",
        ]
        for key in ["js-flags", "chromium-args", "user-agent"] {
            if let value = original[key] { package[key] = value }
        }

        if var window = original["window"] as? [String: Any] {
            // The icon is a path relative to the game's own package, which is
            // one level further down here.
            if let icon = window["icon"] as? String {
                window["icon"] = "\(gameLink)/\(icon)"
            }
            // An empty title in the package is a title NW.js honors, and the
            // window then has none; RPG Maker writes one because Windows
            // names the window from elsewhere. Dropped, so the page's own
            // `<title>` names the window, which is the game.
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

    /// The game's page relative to its own package root, which is where the
    /// game's `package.json` names it from too.
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

    /// The greenworks preload and the shim it answers with, copied into the
    /// wrapper. They find each other by `__dirname`, so they travel together
    /// and are never loaded from the bundle in place.
    private static let nodeResources = ["preload.js", "greenworks.js"]

    /// The node-side entry point, written only for a game that bundles
    /// greenworks and only when the preload is in the bundle to copy — the
    /// shim it installs opens a connection to the bottle-side stub, which a
    /// game that never asks for an achievement has no use for.
    ///
    /// It exists rather than naming the preload directly because NW.js makes
    /// `node-main` the process's main module, and RPG Maker reads its save
    /// directory out of that module's path
    /// (`path.dirname(process.mainModule.filename) + '/save/'`,
    /// `rpg_managers.js:755`). Left alone, every save would land beside the
    /// preload. Answers `nil` when there is no preload, and the wrapper then
    /// has no `node-main` at all.
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

    /// Removes the node entry and the scripts it loads, for a game that no
    /// longer wants them.
    private static func removeNodeMain(in directory: URL) {
        for name in nodeResources + [nodeMain] {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// What the wrapper package names as its node entry: a name, not a path,
    /// so NW.js resolves it inside the application it was handed.
    private static let nodeMain = "node-main.js"

    /// A path as a JavaScript string literal. JSON escapes forward slashes,
    /// which is valid JavaScript and unreadable in a path.
    private static func quoted(_ text: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [text])) ?? Data()
        let array = String(decoding: data, as: UTF8.self)
        return String(array.dropFirst().dropLast())
            .replacingOccurrences(of: #"\/"#, with: "/")
    }

    /// Removes the wrappers of every game that is not on the native runner —
    /// what a switch back to wine leaves behind otherwise.
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

    /// What a native run appears as: Steam's name for the game, then the
    /// game's own window title, then the app id. Recorded by detection, so a
    /// game that has never been looked at still gets something to show.
    static func title(appID: Int, info: NWJSInfo?) -> String {
        if let name = GameConfig.game(appID).name, !name.isEmpty { return name }
        if let info, let package = (try? Data(contentsOf: URL(fileURLWithPath: info.dir)
                .appendingPathComponent("package.json")))
            .flatMap({ try? JSONSerialization.jsonObject(with: $0) }) as? [String: Any],
            let window = package["window"] as? [String: Any],
            let title = window["title"] as? String, !title.isEmpty { return title }
        return "App \(appID)"
    }

    /// A title as a file name: the separators a path cannot carry, and
    /// nothing else — the Dock shows this, so it stays the game's own name.
    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }

    /// The bundle a native run is exec'd through, built beside the wrapper.
    /// Answers the executable inside it.
    ///
    /// macOS names and icons a Dock tile after the bundle the running
    /// executable lives in, and nothing changes it afterwards — which is why
    /// a game run straight out of the runtime shows NW.js' compass and the
    /// name "nwjs". So each game gets a bundle of its own whose `Contents` is
    /// the runtime's, directory by directory, by symlink: dyld resolves
    /// `@executable_path` from the path a process was started with, so the
    /// symlinked binary finds the framework, the locales and the Chromium
    /// helper apps through our `Contents` and lands on the real ones.
    @discardableResult
    static func writeAppBundle(
        appID: Int, title: String, runtime: URL, in _: URL,
    ) -> URL? {
        let manager = FileManager.default
        // `<runtime>/nwjs.app/Contents/MacOS/nwjs` → the bundle it lives in.
        let source = runtime.deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceContents = source.appendingPathComponent("Contents")
        guard manager.fileExists(atPath: sourceContents.path) else { return nil }

        let stem = fileSafe(title)
        guard !stem.isEmpty else { return nil }
        // Beside the wrapper, never inside it: the wrapper directory is the
        // Chromium application's root, and NW.js from 0.60 on refuses to
        // start an application with a bundle sitting in it (measured — the
        // process runs and no window ever appears).
        // The Dock labels a tile with the bundle's own file name — not
        // `CFBundleName`, not `CFBundleDisplayName`, both of which say the
        // game already (measured: a bundle named after the app id gives a
        // tile that says "1933660"). So the bundle is named after the game,
        // and lives in a directory of its own per app id so that two games
        // sharing a title cannot share a bundle.
        let bundles = bundleDirectory(appID: appID)
        let bundle = bundles.appendingPathComponent("\(stem).app")
        try? manager.createDirectory(at: bundles, withIntermediateDirectories: true)
        // A renamed game leaves a bundle behind that is no longer anyone's.
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
            // Everything the runtime keeps beside its executable — the
            // framework under `Versions` or `Frameworks`, depending on how old
            // the build is. The code signature is deliberately not carried
            // over: this bundle's Info.plist is not the one it covers.
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

    /// Chromium reads its manifest, its scripting definition and its own
    /// icons out of `Contents/Resources` by name, so every one of the
    /// runtime's is reachable here — as links, beside the one file that is
    /// ours.
    ///
    /// Every one except the localized `.lproj` directories: each holds an
    /// `InfoPlist.strings` naming the application "nwjs", and a localized
    /// name beats the one in `Info.plist`, so linking them would undo the
    /// renaming this whole bundle exists for. Chromium's own interface
    /// strings are in the framework's `locale.pak` files and are not affected.
    private static func writeResources(from source: URL, to destination: URL, icon: URL?) throws {
        let manager = FileManager.default
        let ours = "\(iconName).icns"
        var wanted: Set<String> = []
        for entry in (try? manager.contentsOfDirectory(
            at: source, includingPropertiesForKeys: nil,
        )) ?? [] {
            let name = entry.lastPathComponent
            if entry.pathExtension == "lproj" { continue }
            // Ours wins over the runtime's own `app.icns`, when there is one.
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

    /// The runtime's own plist with the game's identity written over it —
    /// everything else is Chromium's, which reads its own keys out of it.
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
        // The bundle identifier stays the runtime's. Chromium builds the name
        // of the Mach service its renderers hand their task ports over from
        // the bundle identifier, on both sides, and the helper app inside the
        // framework carries the runtime's — an identifier of our own gives
        // `bootstrap_look_up: Unknown service name` and a browser process with
        // no renderer and no window (measured on 0.29.4).
        // The name form is what a modern icon asset is looked up by, and this
        // bundle has none — left in, the tile falls back to a generic icon.
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

    /// The native processes of one game, told apart by descent: NW.js is
    /// started with the wrapper directory as its argument, and every helper
    /// it spawns carries the same path, so the command line names them all —
    /// and the one that is nobody else's child is the browser.
    ///
    /// Descent rather than the path, because where Chromium keeps its helper
    /// binaries moved between the versions this has to run: under
    /// `Contents/Versions` in the build a 2018 game asks for, inside the
    /// framework in a current one.
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

    /// The browser and helpers among `ps -axo pid=,ppid=,command=` lines
    /// whose command names `directory` as a whole path: the path followed by
    /// `/`, a space or the end of the line. App 400's wrapper is not a prefix
    /// match for app 4000's.
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

    /// Ends a native run. Steam's own terminate reaches into the bottle, and
    /// the game is no longer there — the client drops its record and the
    /// process keeps running, so it is asked to quit here.
    ///
    /// The browser process alone, when there is one: it takes its renderers
    /// and its crash handler down with it, and killing those directly leaves
    /// orphans holding the profile that the next run has to fight for.
    @discardableResult
    static func terminate(appID: Int) -> [pid_t] {
        let running = runningProcesses(appID: appID)
        let targets = running.browser.isEmpty ? running.helpers : running.browser
        for pid in targets { kill(pid, SIGTERM) }
        return targets
    }

    // MARK: - Browsing data

    /// Points the macOS browsing-data directory at the bottle's, so
    /// localStorage and IndexedDB — where RPG Maker keeps options and some
    /// plugins keep their state — survive a switch either way. RPG Maker's
    /// save files need nothing: they live inside the game directory, which
    /// both runners read at the same path.
    ///
    /// A real directory already at the macOS path belongs to something else
    /// and is left alone; that game keeps two stores, which is the state it
    /// was already in.
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
            // A link of ours into another bottle, from an engine or bottle
            // switch: repointed. Anything else is someone's own arrangement.
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
