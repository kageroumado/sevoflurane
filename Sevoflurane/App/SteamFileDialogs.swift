import AppKit
import UniformTypeIdentifiers

/// Steam's own file dialogs, answered by the Mac's.
///
/// The client's `SteamClient.System.OpenFileDialog` opens a Win32 dialog
/// from `steam.exe`, which this app keeps off the screen with the rest of
/// the client's native windows, so Add a Non-Steam Game's Browse and every
/// other picker in Steam's UI showed nothing. The call is taken on its way
/// to the client and answered with the Mac panel's choice as a Windows path
/// on the bottle's drives: `C:` inside the bottle, `Z:` (the whole
/// filesystem) everywhere else.
@MainActor
enum SteamFileDialogs {
    /// Steam's `EResult` for a dialog the user dismissed; the page reads it
    /// off the rejection and goes quiet.
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

    /// Presents the panel the options describe, as a sheet on the calling
    /// window or the one the user is working in, and answers the choice as a
    /// Windows path, or `nil` for a dismissed panel.
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

    /// The panel's filter for Steam's `*.ext` patterns; empty, which lets
    /// any file through, when one of them is `*.*` — Steam's "All files",
    /// which its own dialog offers beside the default filter and an open
    /// panel has no menu to switch to.
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

    /// The folder the panel opens in: the initial file's own folder, or the
    /// initial path itself when it names a folder (a directory picker's
    /// current choice). `nil` for a path the bottle cannot resolve.
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

    /// The last component of a Windows path, which is all a save panel's
    /// name field takes.
    nonisolated static func fileName(_ windowsPath: String) -> String {
        windowsPath.split(whereSeparator: { $0 == "\\" || $0 == "/" }).last.map(String.init) ?? ""
    }
}

/// Steam's Add desktop shortcut, as a Mac desktop understands it: an alias
/// of the game's own bundle, which carries the game's icon and starts it
/// through the app. The client would have written a `.url` file to the
/// bottle's Windows desktop, where nobody looks.
@MainActor
enum DesktopShortcuts {
    /// Takes the call for the game, a Steam app or a non-Steam shortcut.
    /// `false` when the game has no bundle to point at yet.
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
        let fileName = String(name.map { $0 == "/" || $0 == ":" ? "-" : $0 })
        let alias = desktop.appendingPathComponent(fileName)
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
}
