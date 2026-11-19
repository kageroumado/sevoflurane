import AppKit
import UniformTypeIdentifiers

/// Steam's file dialogs, answered by the Mac's. `SteamClient.System.OpenFileDialog`
/// would open an off-screen Win32 dialog, so the call is answered with the
/// panel's choice as a Windows path: `C:` inside the bottle, `Z:` elsewhere.
@MainActor
enum SteamFileDialogs {
    /// Steam's `EResult` for a dismissed dialog.
    nonisolated static let cancelledResult = 52

    /// What the page asked for, read off the call's one argument.
    struct Options: Sendable {
        var title: String?
        var initialFile = ""
        var patterns: [String] = []
        var saveMode = false
        var chooseDirectory = false

        nonisolated init(_ call: [String: Any]) {
            title = call["strTitle"] as? String
            initialFile = call["strInitialFile"] as? String ?? ""
            patterns = (call["rgFilters"] as? [[String: Any]] ?? [])
                .flatMap { $0["rFilePatterns"] as? [String] ?? [] }
            saveMode = call["bSaveMode"] as? Bool == true
            chooseDirectory = call["bChooseDirectory"] as? Bool == true
        }
    }

    /// Presents the panel as a sheet and answers the choice as a Windows
    /// path, or `nil` when dismissed.
    static func choose(_ options: Options, over window: NSWindow? = nil) async -> String? {
        let panel: NSSavePanel
        let types = contentTypes(patterns: options.patterns)
        let initial = initialLocation(options.initialFile)
        if options.saveMode {
            panel = NSSavePanel()
            panel.nameFieldStringValue = fileName(options.initialFile)
            if !types.isEmpty {
                panel.allowedContentTypes = types
            }
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = !options.chooseDirectory
            open.canChooseDirectories = options.chooseDirectory
            open.allowsMultipleSelection = false
            if !types.isEmpty {
                open.allowedContentTypes = types
            }
            panel = open
        }
        panel.directoryURL = initial
        if let title = options.title, !title.isEmpty {
            panel.title = title
            panel.message = title
        }
        guard await WebFilePanel.present(panel, over: window) == .OK, let chosen = panel.url else { return nil }
        EventLog.shared.log(.client, "Steam's file dialog: chose \(chosen.lastPathComponent)")
        return SteamBottle.windowsPath(for: chosen)
    }

    /// The panel's filter for Steam's `*.ext` patterns; empty (any file) when
    /// one is `*.*`, since an open panel has no filter menu.
    nonisolated static func contentTypes(patterns: [String]) -> [UTType] {
        var extensions: [String] = []
        for pattern in patterns {
            guard pattern.hasPrefix("*.") else { continue }
            let name = String(pattern.dropFirst(2))
            if name.contains("*") { return [] }
            extensions.append(name)
        }
        return WebFilePanel.contentTypes(extensions: extensions)
    }

    /// The folder the panel opens in: the initial path's folder, or the path
    /// itself when it is one.
    private static func initialLocation(_ windowsPath: String) -> URL? {
        guard !windowsPath.isEmpty else { return nil }
        let trimmed = windowsPath.hasPrefix("\"") && windowsPath.hasSuffix("\"") && windowsPath.count > 1
            ? String(windowsPath.dropFirst().dropLast()) : windowsPath
        if let url = SteamBottle.macURL(fromWindowsPath: trimmed) {
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
            return isDirectory.boolValue ? url : url.deletingLastPathComponent()
        }
        // A save dialog's suggested file does not exist yet; its folder may.
        let folder = trimmed.split(whereSeparator: { $0 == "\\" || $0 == "/" }).dropLast().joined(separator: "\\")
        return folder.isEmpty ? nil : SteamBottle.macURL(fromWindowsPath: folder)
    }

    /// The last component of a Windows path.
    nonisolated static func fileName(_ windowsPath: String) -> String {
        windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
    }
}

/// Steam's Add desktop shortcut as an alias of the game's bundle on the Mac
/// Desktop, in place of a `.url` on the bottle's Windows desktop.
@MainActor
enum DesktopShortcuts {
    /// Takes the call for a Steam app or non-Steam shortcut; `false` without a bundle yet.
    static func take(appID steamID: Int) -> Bool {
        guard let delegate = NSApp.delegate as? AppDelegate else { return false }
        let appID = delegate.host.shortcutPrograms[steamID] ?? steamID
        let name = AdoptedPrograms.entry(appID)?.name
            ?? delegate.host.libraryGames.first { $0.id == appID }?.name
            ?? GameConfig.game(appID).name ?? String(appID)
        guard let bundle = GameLaunchers.dockableBundle(appID: appID) else {
            EventLog.shared.log(.client, "desktop shortcut for \(name): no bundle yet, it is made by the first launch")
            return false
        }
        let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
        let alias = Self.aliasURL(named: name, in: desktop)
        do {
            let data = try bundle.bookmarkData(
                options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil,
            )
            try URL.writeBookmarkData(data, to: alias)
            EventLog.shared.log(.client, "desktop shortcut for \(name): alias on the Desktop")
            NSWorkspace.shared.activateFileViewerSelecting([alias])
            return true
        } catch {
            EventLog.shared.log(.client, "desktop shortcut for \(name): could not write the alias — \(error.localizedDescription)")
            return false
        }
    }

    /// Where a game's alias goes. The name is the game's own, so it is kept
    /// from hiding the file or replacing one the person put there: an alias
    /// we wrote before is rewritten, anything else is left and the alias
    /// takes a name beside it.
    nonisolated static func aliasURL(named name: String, in folder: URL) -> URL {
        var fileName = String(name.map { $0 == "/" || $0 == ":" || $0.isNewline ? "-" : $0 })
        while fileName.hasPrefix(".") { fileName.removeFirst() }
        if fileName.isEmpty { fileName = "Game" }
        let wanted = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: wanted.path),
              (try? wanted.resourceValues(forKeys: [.isAliasFileKey]))?.isAliasFile != true
        else { return wanted }
        return folder.appendingPathComponent("\(fileName) (Sevoflurane)")
    }
}
