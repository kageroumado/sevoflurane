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

    static let root = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Sevoflurane/Launchers")

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
            // A renamed game leaves a bundle behind that is no longer anyone's.
            for entry in (try? manager.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil,
            )) ?? [] where entry.lastPathComponent != bundle.lastPathComponent {
                try? manager.removeItem(at: entry)
            }
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
            var copied = !manager.isExecutableFile(atPath: executable.path)
                || recordedEngine(in: contents) != engine.preferenceValue
            if copied {
                for (source, name) in loaderFiles(loader, stem: stem) {
                    let destination = contents.appendingPathComponent("MacOS/\(name)")
                    try? manager.removeItem(at: destination)
                    try manager.copyItem(at: source, to: destination)
                }
            }
            if let icon = GameIcon.icns(appID: appID, title: title) {
                let destination = contents.appendingPathComponent("Resources/\(iconName).icns")
                if !manager.contentsEqual(atPath: icon.path, andPath: destination.path) {
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
            let plist = writePlist(
                to: contents.appendingPathComponent("Info.plist"),
                title: title, stem: stem, appID: appID, hasIcon: hasIcon, engine: engine,
            )
            let stamp = Data("APPL????".utf8)
            let pkgInfo = contents.appendingPathComponent("PkgInfo")
            if (try? Data(contentsOf: pkgInfo)) != stamp { try stamp.write(to: pkgInfo) }
            // The signature covers the plist and the executable, so it is
            // renewed whenever either of them was.
            if copied || plist { sign(bundle) }
        } catch {
            log("launcher: could not build \(title)'s bundle: \(error.localizedDescription)")
            return nil
        }
        return executable
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

    /// Answers whether it wrote, so a signature is only renewed when the
    /// thing it covers changed.
    private static func writePlist(
        to destination: URL, title: String, stem: String,
        appID: Int, hasIcon: Bool, engine: Engine,
    ) -> Bool {
        var plist: [String: Any] = [
            "CFBundleName": title,
            "CFBundleDisplayName": title,
            "CFBundleIdentifier": "glass.kagerou.sevoflurane.game.\(appID)",
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
        if hasIcon { plist["CFBundleIconFile"] = iconName }
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
