import Foundation

/// A bundle per game whose executable is the wine loader, so that a bottled
/// game is an application of its own to macOS.
///
/// macOS reads a running process's name, its Dock icon and its eligibility
/// for Game Mode out of the bundle **its own executable lives in**. A wine
/// game's executable is the engine's loader, so all three say "wine", and a
/// launcher that execs the loader elsewhere loses the attribution again. So
/// each game gets a copy of the loader inside a bundle named after it, and the
/// engine starts the game through that copy (`SEVO_LOADER` in the game's env
/// file, read by ntdll's `loader_exec`).
///
/// Game Mode also needs the process frontmost and its window covering the
/// screen; the bundle supplies only the games category.
nonisolated enum GameLaunchers {
    /// Where the launcher logs: stderr, or the app's event log.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = {
        FileHandle.standardError.write(Data(($0 + "\n").utf8))
    }

    static let root = AppIdentity.supportFolder
        .appendingPathComponent("Launchers")

    /// The app's Dock tile plug-in, which the Dock loads from a kept tile
    /// while the game is not running.
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

    /// What a tile shows while the game is not running, read by the plug-in.
    static func tileStateFile(appID: Int) -> URL {
        directory(appID: appID).appendingPathComponent(tileStateName)
    }

    private static let tileStateName = "tile.json"

    /// The renderers the tile's Play with menu offers, for every game.
    static var renderersFile: URL {
        root.appendingPathComponent("renderers.json")
    }

    /// Whether any game has a bundle, cheaply.
    static var hasBundles: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? [])
            .contains { Int($0) != nil }
    }

    /// One directory per app id, so two games sharing a title never share a
    /// bundle.
    static func directory(appID: Int) -> URL {
        root.appendingPathComponent(String(appID))
    }

    /// Builds or refreshes the game's bundle and answers its loader; `nil`
    /// for CrossOver or a game with no name.
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
            // Never a symlink: measured on Subnautica 2, a symlinked loader
            // gets the Dock tile, icon and LaunchServices identity right but
            // leaves Game Mode off, while a copy turns it on, signed or not.
            // `codesign` breaks a hard link into a copy anyway. Signing
            // rewrites the copy, so the engine the bundle records decides a
            // re-copy rather than the bytes.
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
                    // LaunchServices caches the icon against the bundle's date.
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

    /// The game's bundle when its loader carries the handoff that sends a
    /// program-less open to `sevoflurane://play/<id>`.
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

    static let dockHandoff = "sevoflurane://play/"

    /// `<appid>/<Title>.app — <engine>` per bundle, for diagnostics.
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

    /// Removes a renamed game's old bundle; the tile state file stays.
    private static func removeOtherBundles(in directory: URL, keeping bundle: URL) {
        let manager = FileManager.default
        for entry in (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
        )) ?? [] where entry.lastPathComponent != bundle.lastPathComponent
            && entry.lastPathComponent != tileStateName {
            try? manager.removeItem(at: entry)
        }
    }

    /// The engine a bundle's loader was copied from.
    private static func recordedEngine(in contents: URL) -> String? {
        guard let data = try? Data(contentsOf: contents.appendingPathComponent("Info.plist")),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, format: nil,
              ) as? [String: Any]
        else { return nil }
        return plist[engineKey] as? String
    }

    private static let engineKey = "SevofluraneEngine"

    /// The loader and its preloader: `preloader_exec` tries
    /// `<loader>-preloader` first.
    private static func loaderFiles(_ loader: URL, stem: String) -> [(URL, String)] {
        var files = [(loader, stem)]
        let preloader = loader.deletingLastPathComponent()
            .appendingPathComponent("\(loader.lastPathComponent)-preloader")
        if FileManager.default.fileExists(atPath: preloader.path) {
            files.append((preloader, "\(stem)-preloader"))
        }
        return files
    }

    /// Copies the app's Dock tile plug-in into the bundle when its content
    /// differs (a later install can be older). Answers whether one is there
    /// and whether this call wrote it.
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

    /// Answers whether it wrote.
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
            // Game Mode needs the games category.
            "LSApplicationCategoryType": "public.app-category.games",
            "GCSupportsGameMode": true,
            "NSHighResolutionCapable": true,
            // A bundle built against another engine is rebuilt.
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
    /// its executable carries the identity its plist claims. Game Mode turns
    /// on for an unsigned copy as well.
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
