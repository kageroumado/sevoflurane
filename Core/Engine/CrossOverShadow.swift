import Foundation

/// A stand-in `CX_ROOT` that swaps CrossOver's D3DMetal for one we manage.
///
/// CrossOver's Perl launcher derives `CX_ROOT` from its own location and sets
/// `CX_APPLEGPTK_LIBD3DSHARED_PATH` under it, and that library loads the
/// D3DMetal framework beside it. Run from a tree of symlinks where only
/// `lib64/apple_gptk` differs, it loads our D3DMetal and `CrossOver.app`'s
/// signature stays intact. A bottle's `[EnvironmentVariables]` apply before
/// the launcher sets the path, and the hardened runtime strips `DYLD_*`.
nonisolated enum CrossOverShadow {
    static let root = AppIdentity.supportFolder
        .appendingPathComponent("CrossOverShadow")

    /// The tree's launcher, or `nil` when the tree is missing.
    static var launcher: URL? {
        let wine = root.appendingPathComponent("bin/wine")
        return FileManager.default.fileExists(atPath: wine.path) ? wine : nil
    }

    /// Builds the tree with `apple_gptk` pointing at `d3dmetal`'s
    /// `lib/external` and `lib/wine` (``D3DMetalInstaller``).
    static func build(pointingAt d3dmetal: URL, crossOver: URL) throws {
        let manager = FileManager.default
        // Assembled beside the destination and moved into place, since any
        // wine invocation, app or CLI, can build at once.
        discardAbandonedStaging()
        let staging = root.deletingLastPathComponent()
            .appendingPathComponent("CrossOverShadow-\(UUID().uuidString)")
        try manager.createDirectory(
            at: staging.deletingLastPathComponent(), withIntermediateDirectories: true,
        )
        defer { try? manager.removeItem(at: staging) }
        try assemble(in: staging, pointingAt: d3dmetal, crossOver: crossOver)
        // Swap rather than delete-then-move, so a tree another process just
        // published is never missing.
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

    /// `FileManager` removes links without following them, so the tree is
    /// safe to throw away.
    private static func assemble(
        in root: URL, pointingAt d3dmetal: URL, crossOver: URL,
    ) throws {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true)

        // Everything but lib64 is CrossOver's, hidden entries included.
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

    /// Whether the tree's stamp matches this CrossOver and D3DMetal.
    static func isCurrent(crossOver: URL, d3dmetal: URL) -> Bool {
        guard launcher != nil,
              let data = try? Data(contentsOf: root.appendingPathComponent("sevo-stamp")),
              let recorded = String(data: data, encoding: .utf8)
        else { return false }
        return recorded == stamp(crossOver: crossOver, d3dmetal: d3dmetal)
    }

    /// The launcher for the pinned D3DMetal, building the tree when stale;
    /// `nil` when nothing is pinned.
    static func preparedLauncher() -> URL? {
        guard let pinned = D3DMetalInstaller.active(inEngine: D3DMetalInstaller.sharedRoot)
        else {
            remove()
            return nil
        }
        // A dangling path makes CrossOver's launcher set no graphics library
        // at all.
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
                // CrossOver's own launcher runs this invocation; any tree
                // another process published is left alone.
                SetupLog.log("could not build the CrossOver shadow tree: \(error)")
                return isCurrent(crossOver: crossOver, d3dmetal: pinned.root) ? launcher : nil
            }
        }
        return launcher
    }

    static func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Removes staging trees left by a killed process.
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

    /// Paths, CrossOver's version, and the mirrored directory's modification
    /// date, which moves when an update adds or removes an entry.
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
