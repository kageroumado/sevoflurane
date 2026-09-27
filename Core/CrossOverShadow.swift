import Foundation

/// A stand-in `CX_ROOT` that swaps CrossOver's D3DMetal for one we manage.
///
/// CrossOver's launcher is a Perl script that derives `CX_ROOT` from its own
/// location and then hands Wine
/// `CX_APPLEGPTK_LIBD3DSHARED_PATH=$CX_ROOT/lib64/apple_gptk/external/libd3dshared.dylib`.
/// Wine's `ntdll` dlopens that, and the library dlopens
/// `@rpath/D3DMetal.framework/D3DMetal` against `@loader_path` — so the
/// framework is always the one beside the library that was loaded.
///
/// Running the launcher from a tree of symlinks therefore changes which
/// D3DMetal a game gets, and changes nothing else: everything but
/// `lib64/apple_gptk` points straight back at CrossOver's own files. Nothing
/// is written inside `CrossOver.app`, so its signature stays intact — which
/// is the whole reason CodeWeavers cannot offer this themselves.
///
/// The alternatives do not work: a bottle's `[EnvironmentVariables]` are
/// applied *before* the launcher sets that path, and `DYLD_*` is stripped
/// because `wineloader` runs under the hardened runtime.
nonisolated enum CrossOverShadow {
    static let root = UserHome.url
        .appendingPathComponent("Library/Application Support/Sevoflurane/CrossOverShadow")

    /// The launcher to run instead of CrossOver's, or `nil` when the tree is
    /// missing or stale beyond repair — in which case the caller uses
    /// CrossOver's own and the user gets CrossOver's own D3DMetal.
    static var launcher: URL? {
        let wine = root.appendingPathComponent("bin/wine")
        return FileManager.default.fileExists(atPath: wine.path) ? wine : nil
    }

    /// Builds (or rebuilds) the tree so that `apple_gptk` is `d3dmetal`.
    ///
    /// `d3dmetal` is a directory holding Apple's own `lib/external` and
    /// `lib/wine` — what ``D3DMetalInstaller`` unpacks from the toolkit.
    static func build(pointingAt d3dmetal: URL, crossOver: URL) throws {
        let manager = FileManager.default
        // Assembled beside the destination and moved into place, so two
        // processes building at once cannot see each other's half-built tree
        // — `Engine.wineURL` runs on any wine invocation, app or CLI.
        discardAbandonedStaging()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("CrossOverShadow-\(UUID().uuidString)")
        try manager.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        defer { try? manager.removeItem(at: staging) }
        try assemble(in: staging, pointingAt: d3dmetal, crossOver: crossOver)
        // Swap rather than delete-then-move: another process may have
        // finished its own build in the meantime, and the tree it published
        // must never be taken away by someone else's slower copy.
        let displaced = staging.appendingPathExtension("previous")
        let hadTree = (try? manager.moveItem(at: root, to: displaced)) != nil
        do {
            try manager.moveItem(at: staging, to: root)
        } catch {
            if hadTree { try? manager.moveItem(at: displaced, to: root) }
            throw error
        }
        if hadTree { try? manager.removeItem(at: displaced) }
    }

    /// Removing a tree of symlinks removes the links, never what they point
    /// at: `FileManager` does not follow them, which is what makes a tree of
    /// links into `/Applications` safe to throw away.
    private static func assemble(
        in root: URL, pointingAt d3dmetal: URL, crossOver: URL,
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // Everything except lib64 is CrossOver's, verbatim. Hidden entries
        // included: `contentsOfDirectory` skips none unless asked to, and a
        // tree missing one would fail in ways nobody would trace back here.
        for entry in try manager.contentsOfDirectory(at: crossOver, includingPropertiesForKeys: nil)
            where entry.lastPathComponent != "lib64" {
            try manager.createSymbolicLink(
                at: root.appendingPathComponent(entry.lastPathComponent), withDestinationURL: entry,
            )
        }
        // lib64 is CrossOver's too, except for the one directory this exists for.
        let lib64 = root.appendingPathComponent("lib64")
        try manager.createDirectory(at: lib64, withIntermediateDirectories: true)
        let crossOverLib64 = crossOver.appendingPathComponent("lib64")
        for entry in try manager.contentsOfDirectory(
            at: crossOverLib64, includingPropertiesForKeys: nil,
        ) where entry.lastPathComponent != "apple_gptk" {
            try manager.createSymbolicLink(
                at: lib64.appendingPathComponent(entry.lastPathComponent), withDestinationURL: entry,
            )
        }
        let gptk = lib64.appendingPathComponent("apple_gptk")
        try manager.createDirectory(at: gptk, withIntermediateDirectories: true)
        try manager.createSymbolicLink(
            at: gptk.appendingPathComponent("external"),
            withDestinationURL: d3dmetal.appendingPathComponent("lib/external"),
        )
        try manager.createSymbolicLink(
            at: gptk.appendingPathComponent("wine"),
            withDestinationURL: d3dmetal.appendingPathComponent("lib/wine"),
        )
        try Data(stamp(crossOver: crossOver, d3dmetal: d3dmetal).utf8)
            .write(to: root.appendingPathComponent("sevo-stamp"))
    }

    /// Whether the tree still describes this CrossOver and this D3DMetal. A
    /// CrossOver update moves files the symlinks point at, and the stamp is
    /// how that is noticed without walking the tree.
    static func isCurrent(crossOver: URL, d3dmetal: URL) -> Bool {
        guard launcher != nil,
              let data = try? Data(contentsOf: root.appendingPathComponent("sevo-stamp")),
              let recorded = String(data: data, encoding: .utf8)
        else { return false }
        return recorded == stamp(crossOver: crossOver, d3dmetal: d3dmetal)
    }

    /// The launcher to run for the pinned D3DMetal, building or refreshing
    /// the tree if it is missing or describes a CrossOver that has since been
    /// updated. `nil` whenever nothing is pinned, so the ordinary path costs
    /// one preference read.
    static func preparedLauncher() -> URL? {
        guard let pinned = D3DMetalInstaller.active(inEngine: D3DMetalInstaller.sharedRoot)
        else {
            remove()
            return nil
        }
        // The pinned version can be gone — a support folder cleared, a
        // directory deleted by hand. Its symlinks would dangle, and
        // CrossOver's launcher tests that path with `-f`: it would then set
        // no graphics library at all rather than falling back to its own.
        guard FileManager.default.fileExists(
            atPath: pinned.root.appendingPathComponent("lib/external/libd3dshared.dylib").path,
        ) else {
            SetupLog.log("pinned D3DMetal \(pinned.version) is missing — using CrossOver's")
            remove()
            return nil
        }
        let crossOver = URL(fileURLWithPath: SteamBottle.crossoverBin).deletingLastPathComponent()
        guard FileManager.default.fileExists(
            atPath: crossOver.appendingPathComponent("lib64/apple_gptk").path,
        ) else { return nil }
        if !isCurrent(crossOver: crossOver, d3dmetal: pinned.root) {
            do {
                try build(pointingAt: pinned.root, crossOver: crossOver)
                SetupLog.log("D3DMetal \(pinned.version): rebuilt the CrossOver shadow tree")
            } catch {
                // A failure here is this invocation's problem, not the tree's:
                // CrossOver's own launcher runs the game, and whatever tree
                // exists — quite possibly one another process just published
                // — is left alone.
                SetupLog.log("could not build the CrossOver shadow tree: \(error)")
                return isCurrent(crossOver: crossOver, d3dmetal: pinned.root) ? launcher : nil
            }
        }
        return launcher
    }

    static func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Half-built trees from a process that was killed between assembling and
    /// swapping. They are only ever ours, and only ever symlinks.
    private static func discardAbandonedStaging() {
        let manager = FileManager.default
        let parent = root.deletingLastPathComponent()
        let siblings = (try? manager.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil,
        )) ?? []
        for entry in siblings
            where entry.lastPathComponent.hasPrefix("CrossOverShadow-") {
            try? manager.removeItem(at: entry)
        }
    }

    /// What the tree was built from, in enough detail that a CrossOver update
    /// invalidates it: the bundle's version, and the modification date of the
    /// directory the top-level links mirror — which moves when an update adds
    /// or removes an entry the tree would otherwise miss.
    private static func stamp(crossOver: URL, d3dmetal: URL) -> String {
        let plist = crossOver.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Info.plist")
        let info = (try? Data(contentsOf: plist)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any]
        }
        let version = info?["CFBundleShortVersionString"] as? String ?? "?"
        let modified = (try? FileManager.default.attributesOfItem(atPath: crossOver.path))?[
            .modificationDate,
        ] as? Date
        return [
            crossOver.path, d3dmetal.path, version,
            String(modified?.timeIntervalSince1970 ?? 0),
        ].joined(separator: "\n")
    }
}
