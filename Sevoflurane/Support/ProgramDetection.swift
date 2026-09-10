import Foundation

/// What kind of Windows program a file is, decided before it runs.
///
/// An installer and a game want opposite treatment — one is run once and
/// judged by what it leaves on disk, the other is kept and started again — and
/// asking the user to classify their own download is asking them to know how
/// this app works. The file says enough by itself: its name, the strings in
/// its version resource, the privilege its manifest asks for, the installer
/// toolkits' own markers, and what lies beside it in its folder.
nonisolated enum ProgramDetection {
    /// A kind and the signals that chose it, so the panel can show its work.
    struct Verdict: Sendable, Equatable {
        /// One of ``ProgramKind``.
        let kind: String
        /// Why, shortest first, for the line under the program's name.
        let reasons: [String]

        /// The verdict as one sentence.
        var summary: String {
            let what = switch kind {
            case ProgramKind.installer: "Looks like an installer"
            case ProgramKind.game: "Looks like a game"
            default: "A Windows program"
            }
            return reasons.isEmpty ? what : "\(what): \(reasons.joined(separator: ", "))"
        }
    }

    /// Classifies one executable. An installer's signals win: running a game
    /// once costs a launch, while adopting an installer leaves a Quick Launch
    /// entry that reinstalls something every time it is clicked.
    static func classify(_ url: URL) -> Verdict {
        let info = PEResources.read(url)
        let installer = installerSignals(url, info: info)
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
            reasons.append("named \u{201C}\(fragment)\u{201D}")
        }
        if let described = versionSaysInstaller(info) {
            reasons.append("its version resource says \u{201C}\(described)\u{201D}")
        }
        if info?.requestedExecutionLevel == "requireAdministrator" {
            reasons.append("it asks for administrator")
        }
        if let toolkit = toolkit(in: url) {
            reasons.append("built with \(toolkit)")
        }
        if let sibling = installerSibling(url) {
            reasons.append("\(sibling) beside it")
        }
        return reasons
    }

    /// The word in the version resource that names an installer, if one is
    /// there.
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

    /// The installer toolkit whose marker sits in the file's own stub, which
    /// is within the first megabytes of it.
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

    /// Files a game engine ships that nothing else does.
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
            reasons.append("Steam's API beside it")
        }
        for (file, engine) in engineFiles.sorted(by: { $0.key < $1.key })
            where files.contains(file) {
            reasons.append("\(engine) beside it")
        }
        if directories.contains(where: { $0.hasSuffix("_data") }) {
            reasons.append("a game data folder beside it")
        }
        if directories.contains("engine") {
            reasons.append("an Engine folder beside it")
        }
        if files.contains(where: { $0.hasPrefix("d3d") && $0.hasSuffix(".dll") }) {
            reasons.append("Direct3D libraries beside it")
        }
        if files.contains(where: { $0.hasSuffix(".pak") }) {
            reasons.append("packed game data beside it")
        }
        // The tool-name exclusions the library scan uses: a crash reporter
        // sitting in a game's folder inherits every signal above.
        guard GameExecutables.isGameLike(url.lastPathComponent.lowercased()) else { return [] }
        return reasons
    }
}
