import Foundation

/// A bundle per game whose executable is the wine loader, so that a bottled
/// game is an application of its own to macOS.
///
/// macOS reads a running process's name, its Dock icon and its eligibility
/// for Game Mode out of the bundle **its own executable lives in**. A wine
/// game's executable is the engine's loader, so all three say "wine"; a
/// launcher that execs the loader somewhere else loses the attribution
/// entirely, because by then the process is the loader again. So each game
/// gets a copy of the loader inside a bundle named after it, and the engine
/// starts the game through that copy (`SEVO_LOADER` in the game's env file,
/// read by ntdll's `loader_exec`).
///
/// Game Mode wants three things at once: the bundle declares
/// the games category, the process is frontmost, and its window covers the
/// screen. This provides the first; the other two are the game's own doing.
nonisolated enum GameLaunchers {
    /// Where the launcher's decisions are narrated. The default reaches
    /// `sevo`'s caller; the app points it at its own event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Launchers")

    /// The Dock tile plug-in every bundle carries, when this process is
    /// inside Sevoflurane.app or beside it: the Dock loads it out of a kept
    /// tile while the game is not running, for the tile's menu and badge.
    static var dockTilePlugIn: URL? {
        var app = Bundle.main.bundleURL
        while app.pathExtension != "app" {
            let parent = app.deletingLastPathComponent()
            guard parent.path != app.path, parent.path != "/" else { return nil }
            app = parent
        }
        let plugIn = app.appendingPathComponent("Contents/PlugIns/\(dockTilePlugInName)")
        return FileManager.default.fileExists(atPath: plugIn.path) ? plugIn : nil
    }

    static let dockTilePlugInName = "SevofluraneDockTile.docktileplugin"

    /// Where the app says what a tile shows while the game is not running:
    /// the plug-in reads it beside the bundle.
    static func tileStateFile(appID: Int) -> URL {
        directory(appID: appID).appendingPathComponent(tileStateName)
    }

    private static let tileStateName = "tile.json"

    /// The renderers the tile's Play with menu offers, for every game at
    /// once: the plug-in reads this beside the bundles.
    static var renderersFile: URL {
        root.appendingPathComponent("renderers.json")
    }

    /// Whether any game has a bundle right now — the cheap question to ask
    /// before the expensive one.
    static var hasBundles: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .contains { Int($0) != nil }
    }

    /// Where a game's bundles live — one directory per app id, so two games
    /// sharing a title cannot share a bundle.
    static func directory(appID: Int) -> URL {
        root.appendingPathComponent(String(appID))
    }

    /// Builds (or refreshes) the game's bundle and answers the loader inside
    /// it, which is what the engine execs. `nil` when the engine has no
    /// loader to copy — CrossOver's tree is not ours to reshape — or when the
    /// game has no name to put on the tile.
    @discardableResult
    static func materialize(appID: Int, title: String, engine: Engine) -> URL? {
        guard case .managed = engine, let loader = engine.unixLoader else { return nil }
        let stem = fileSafe(title)
        guard !stem.isEmpty else { return nil }

        let manager = FileManager.default
        let directory = directory(appID: appID)
        let bundle = directory.appendingPathComponent("\(stem).app")
        let contents = bundle.appendingPathComponent("Contents")
        let executable = contents.appendingPathComponent("MacOS/\(stem)")
        do {
            removeOtherBundles(in: directory, keeping: bundle)
            try manager.createDirectory(
                at: contents.appendingPathComponent("MacOS"), withIntermediateDirectories: true,
            )
            try manager.createDirectory(
                at: contents.appendingPathComponent("Resources"),
                withIntermediateDirectories: true,
            )
            // A copy, and it has to be one. Measured on Subnautica 2, same
            // bundle and plist and a fullscreen window each time: with the
            // executable a **symlink** to the engine's loader the Dock tile,
            // the icon and the LaunchServices identity are all right and Game
            // Mode stays **off**; with a copy it comes **on**. Signing is not
            // what decides it — an unsigned copy carrying the engine's own
            // `org.winehq.wine` identity turns it on too. A hard link is not
            // a middle way: `codesign` breaks it, and the bundle ends up with
            // a copy anyway.
            // Signing rewrites the copy, so it never matches the original
            // again: what decides a re-copy is the engine the bundle records,
            // not the bytes.
            let copied = !manager.isExecutableFile(atPath: executable.path)
                || recordedEngine(in: contents) != engine.preferenceValue
            if copied {
                for (source, name) in loaderFiles(loader, stem: stem) {
                    let destination = contents.appendingPathComponent("MacOS/\(name)")
                    try? manager.removeItem(at: destination)
                    try manager.copyItem(at: source, to: destination)
                }
            }
            var iconChanged = false
            if let icon = GameIcon.icns(appID: appID, title: title) {
                let destination = contents.appendingPathComponent("Resources/\(iconName).icns")
                if !manager.contentsEqual(atPath: icon.path, andPath: destination.path) {
                    iconChanged = true
                    try? manager.removeItem(at: destination)
                    try manager.copyItem(at: icon, to: destination)
                    // LaunchServices caches a bundle's icon against the bundle's
                    // own date; a new icon behind an untouched bundle is served
                    // stale until the bundle itself looks changed.
                    try? manager.setAttributes([.modificationDate: Date()], ofItemAtPath: bundle.path)
                }
            }
            let hasIcon = manager.fileExists(
                atPath: contents.appendingPathComponent("Resources/\(iconName).icns").path,
            )
            let plugIn = copyDockTilePlugIn(into: contents)
            let plist = writePlist(
                to: contents.appendingPathComponent("Info.plist"),
                title: title, stem: stem, appID: appID, engine: engine,
                carrying: (icon: hasIcon, plugIn: plugIn.present),
            )
            let stamp = Data("APPL????".utf8)
            let pkgInfo = contents.appendingPathComponent("PkgInfo")
            if (try? Data(contentsOf: pkgInfo)) != stamp { try stamp.write(to: pkgInfo) }
            // The signature seals the plist, the executable, the icon and the
            // plug-in, so it is renewed whenever any of them was.
            if copied || plist || plugIn.copied || iconChanged {
                sign(bundle)
                log("launcher: built \(stem).app on \(engine.description)")
            }
        } catch {
            log("launcher: could not build \(title)'s bundle: \(error.localizedDescription)")
            return nil
        }
        return executable
    }

    /// The game's bundle, when a Dock tile made of it would start the game:
    /// its loader hands a LaunchServices open with no program to
    /// `sevoflurane://play/<id>`. A loader copied from an engine without that
    /// handoff would print wine's usage and quit, so its bundle is not offered.
    static func dockableBundle(appID: Int) -> URL? {
        let directory = directory(appID: appID)
        guard let bundle = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        ))?.first(where: { $0.pathExtension == "app" }) else { return nil }
        let stem = bundle.deletingPathExtension().lastPathComponent
        let loader = bundle.appendingPathComponent("Contents/MacOS/\(stem)")
        guard let bytes = try? Data(contentsOf: loader, options: .alwaysMapped),
              bytes.range(of: Data(dockHandoff.utf8)) != nil
        else { return nil }
        return bundle
    }

    /// The URL prefix the loader's handoff opens, and what the app answers.
    static let dockHandoff = "sevoflurane://play/"

    /// One line per bundle in the store — `<appid>/<Title>.app` and the
    /// engine its loader was copied from — for a diagnostics report.
    static func inventory() -> [String] {
        let manager = FileManager.default
        let ids = ((try? manager.contentsOfDirectory(atPath: root.path)) ?? [])
            .filter { Int($0) != nil }
            .sorted()
        return ids.flatMap { id -> [String] in
            let directory = root.appendingPathComponent(id)
            let bundles = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).sorted()
            return bundles.map { bundle in
                let contents = directory.appendingPathComponent("\(bundle)/Contents")
                return "\(id)/\(bundle) — \(recordedEngine(in: contents) ?? "engine not recorded")"
            }
        }
    }

    /// Removes the bundles of games that are no longer in the store.
    static func remove(keeping wanted: Set<Int>) {
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil,
        )) ?? [] {
            guard let appID = Int(entry.lastPathComponent), !wanted.contains(appID) else { continue }
            try? manager.removeItem(at: entry)
        }
    }

    // MARK: - The pieces

    private static let iconName = "app"

    /// A renamed game leaves a bundle behind that is no longer anyone's.
    /// The tile's state file lives beside the bundle and stays.
    private static func removeOtherBundles(in directory: URL, keeping bundle: URL) {
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        )) ?? [] where entry.lastPathComponent != bundle.lastPathComponent
            && entry.lastPathComponent != tileStateName {
            try? manager.removeItem(at: entry)
        }
    }

    /// The engine a bundle's loader was copied from, or `nil` for a bundle
    /// that predates the record.
    private static func recordedEngine(in contents: URL) -> String? {
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil,
              ) as? [String: Any]
        else { return nil }
        return plist[engineKey] as? String
    }

    private static let engineKey = "SevofluraneEngine"

    /// The loader, and the preloader beside it when the engine has one:
    /// `preloader_exec` tries `<loader>-preloader` before the loader itself,
    /// so the copy has to be able to answer the same question.
    private static func loaderFiles(_ loader: URL, stem: String) -> [(URL, String)] {
        var files = [(loader, stem)]
        let preloader = loader.deletingLastPathComponent()
            .appendingPathComponent("\(loader.lastPathComponent)-preloader")
        if FileManager.default.fileExists(atPath: preloader.path) {
            files.append((preloader, "\(stem)-preloader"))
        }
        return files
    }

    /// Puts the app's Dock tile plug-in into the bundle, or replaces it when
    /// the app's differs — by content, since a build installed later can be
    /// older. Answers whether one is there, and whether this call wrote it.
    /// A process without the app beside it (a bare `sevo`) leaves whatever
    /// is there.
    private static func copyDockTilePlugIn(into contents: URL) -> (present: Bool, copied: Bool) {
        let manager = FileManager.default
        let destination = contents.appendingPathComponent("PlugIns/\(dockTilePlugInName)")
        let present = manager.fileExists(atPath: destination.path)
        guard let source = dockTilePlugIn else { return (present, false) }
        let binary = "Contents/MacOS/SevofluraneDockTile"
        if present, manager.contentsEqual(
            atPath: source.appendingPathComponent(binary).path,
            andPath: destination.appendingPathComponent(binary).path,
        ) { return (true, false) }
        do {
            try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? manager.removeItem(at: destination)
            try manager.copyItem(at: source, to: destination)
            return (true, true)
        } catch {
            log("launcher: could not copy the Dock tile plug-in: \(error.localizedDescription)")
            return (present, false)
        }
    }

    /// Answers whether it wrote, so a signature is only renewed when the
    /// thing it covers changed.
    private static func writePlist(
        to destination: URL, title: String, stem: String, appID: Int, engine: Engine,
        carrying resources: (icon: Bool, plugIn: Bool),
    ) -> Bool {
        var plist: [String: Any] = [
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundleIdentifier": "\(AppIdentity.identifierStem).game.\(appID)",
            "CFBundleExecutable": stem,
            "CFBundlePackageType": "APPL",
            "CFBundleInfoDictionaryVersion": "6.0",
            // What makes macOS willing to turn Game Mode on for the process.
            "LSApplicationCategoryType": "public.app-category.games",
            "GCSupportsGameMode": true,
            "NSHighResolutionCapable": true,
            // The engine the loader was copied from: a bundle built against
            // an older one is rebuilt rather than left to exec a loader that
            // no longer matches its tree.
            engineKey: engine.preferenceValue,
        ]
        if resources.icon { plist["CFBundleIconFile"] = iconName }
        if resources.plugIn { plist["NSDockTilePlugIn"] = dockTilePlugInName }
        guard let data = try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0,
        ) else { return false }
        guard (try? Data(contentsOf: destination)) != data else { return false }
        try? data.write(to: destination, options: .atomic)
        return true
    }

    /// Ad hoc, so the bundle is a whole one a user can pin to the Dock and
    /// its executable carries the identity its plist claims. Game Mode does
    /// not require it — an unsigned copy is enough for that — so this is for
    /// the bundle's sake rather than the game's.
    private static func sign(_ bundle: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--timestamp=none", bundle.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            log("launcher: could not sign \(bundle.lastPathComponent)")
        }
    }

    private static func fileSafe(_ title: String) -> String {
        let cleaned = title.map { $0 == "/" || $0 == ":" ? "-" : $0 }
        return String(cleaned).trimmingCharacters(in: .whitespaces)
    }
}
