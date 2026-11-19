import Foundation

/// What kind of Windows program a file is, decided before it runs: an installer runs once and is
/// judged by what it leaves, a game is kept and relaunched. The verdict comes from the file's name,
/// version strings, installer-toolkit markers and neighbors. A manifest's privilege request is no
/// signal: games and launchers ask for administrator as often as installers do. The user can
/// overrule a verdict per file (``markNotInstaller(_:)``).
nonisolated enum ProgramDetection {
    /// A kind and the signals that chose it, so the panel can show its work.
    struct Verdict: Sendable, Equatable {
        /// One of ``ProgramKind``.
        let kind: String
        /// Why, shortest first.
        let reasons: [String]

        var summary: String {
            let what = switch kind {
            case ProgramKind.installer: InterfaceCopy.localized("Looks like an installer")
            case ProgramKind.game: InterfaceCopy.localized("Looks like a game")
            default: InterfaceCopy.localized("A Windows program")
            }
            return reasons.isEmpty ? what : "\(what): \(reasons.joined(separator: ", "))"
        }
    }

    /// Classifies one executable. Installer signals win, since an adopted installer reinstalls on
    /// every click while a misjudged game costs one launch; a file the user overruled skips them.
    static func classify(_ url: URL, notInstallers: Set<String> = rememberedNotInstallers()) -> Verdict {
        let isOverruled = notInstallers.contains(url.standardizedFileURL.path)
        let installer = isOverruled ? [] : installerSignals(url, info: PEResources.read(url))
        if !installer.isEmpty {
            return Verdict(kind: ProgramKind.installer, reasons: installer)
        }
        let game = gameSignals(url)
        if !game.isEmpty {
            return Verdict(kind: ProgramKind.game, reasons: game)
        }
        return Verdict(kind: ProgramKind.program, reasons: [])
    }

    // MARK: - Installers

    /// Names installers give themselves.
    private static let installerFragments = [
        "setup", "install", "unins", "redist", "vc_redist", "dxsetup", "update", "patch",
    ]

    /// Byte markers the installer toolkits leave in their own stub.
    private static let toolkitMarkers = [
        "Inno Setup": "Inno Setup",
        "NSIS": "Nullsoft",
        "InstallShield": "InstallShield",
        "WiX": ".wixburn",
    ]

    private static func installerSignals(_ url: URL, info: PEResources.Info?) -> [String] {
        var reasons: [String] = []
        let name = url.lastPathComponent.lowercased()
        if let fragment = installerFragments.first(where: { name.contains($0) }) {
            reasons.append(String(localized: "named \u{201C}\(fragment)\u{201D}"))
        }
        if let described = versionSaysInstaller(info) {
            reasons.append(String(localized: "its version resource says \u{201C}\(described)\u{201D}"))
        }
        if let toolkit = toolkit(in: url) {
            reasons.append(String(localized: "built with \(toolkit)"))
        }
        if let sibling = installerSibling(url) {
            reasons.append(String(localized: "\(sibling) beside it"))
        }
        return reasons
    }

    // MARK: - The user's word

    private static let notInstallersKey = "notInstallers"

    /// The executables the user said are not installers, as standardized paths.
    static func rememberedNotInstallers() -> Set<String> {
        Set(Preferences.shared.stringArray(forKey: notInstallersKey) ?? [])
    }

    /// Remembers that this file is not an installer, for the panel and `sevo program add`.
    static func markNotInstaller(_ url: URL) {
        var paths = rememberedNotInstallers()
        paths.insert(url.standardizedFileURL.path)
        Preferences.shared.set(paths.sorted(), forKey: notInstallersKey)
    }

    /// The version-resource string that names an installer.
    private static func versionSaysInstaller(_ info: PEResources.Info?) -> String? {
        let strings = [info?.productName, info?.fileDescription].compactMap(\.self)
        for text in strings {
            let lowered = text.lowercased()
            for word in ["installer", "install", "setup"] where lowered.contains(word) {
                return text
            }
        }
        return nil
    }

    /// The installer toolkit whose marker is in the first 2 MB of the file.
    private static func toolkit(in url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2 * 1024 * 1024), !head.isEmpty else {
            return nil
        }
        for (toolkit, marker) in toolkitMarkers.sorted(by: { $0.key < $1.key })
            where head.range(of: Data(marker.utf8)) != nil {
            return toolkit
        }
        return nil
    }

    /// A file beside the program that only an installer's payload explains.
    private static func installerSibling(_ url: URL) -> String? {
        let entries = InstallDirectory.entries(in: url.deletingLastPathComponent())
        let names = entries.filter { !$0.isDirectory }.map { $0.name.lowercased() }
        if names.contains(where: { $0.hasSuffix(".msi") }) { return "an .msi" }
        if names.contains("data1.cab") { return "data1.cab" }
        if names.contains("setup.exe"), names.contains(where: { $0.hasSuffix(".bin") }) {
            return "setup.exe and a .bin payload"
        }
        return nil
    }

    // MARK: - Games

    /// Files only a game engine ships.
    private static let engineFiles = [
        "unityplayer.dll": "Unity",
        "nw.dll": "NW.js",
    ]

    private static func gameSignals(_ url: URL) -> [String] {
        var reasons: [String] = []
        let entries = InstallDirectory.entries(in: url.deletingLastPathComponent())
        let files = entries.filter { !$0.isDirectory }.map { $0.name.lowercased() }
        let directories = entries.filter(\.isDirectory).map { $0.name.lowercased() }

        if files.contains(where: { $0.hasPrefix("steam_api") && $0.hasSuffix(".dll") }) {
            reasons.append(InterfaceCopy.localized("Steam's API beside it"))
        }
        for (file, engine) in engineFiles.sorted(by: { $0.key < $1.key })
            where files.contains(file) {
            reasons.append(String(localized: "\(engine) beside it"))
        }
        if directories.contains(where: { $0.hasSuffix("_data") }) {
            reasons.append(InterfaceCopy.localized("a game data folder beside it"))
        }
        if directories.contains("engine") {
            reasons.append(InterfaceCopy.localized("an Engine folder beside it"))
        }
        if files.contains(where: { $0.hasPrefix("d3d") && $0.hasSuffix(".dll") }) {
            reasons.append(InterfaceCopy.localized("Direct3D libraries beside it"))
        }
        if files.contains(where: { $0.hasSuffix(".pak") }) {
            reasons.append(InterfaceCopy.localized("packed game data beside it"))
        }
        // The library scan's tool-name exclusions: a crash reporter in a game's folder shares every
        // signal above.
        guard GameExecutables.isGameLike(url.lastPathComponent.lowercased()) else { return [] }
        return reasons
    }
}
