import AppKit
import UniformTypeIdentifiers

/// Steam's own file dialogs, answered by the Mac's.
///
/// The client's `SteamClient.System.OpenFileDialog` opens a Win32 dialog
/// from `steam.exe`, which this app keeps off the screen with the rest of
/// the client's native windows, so Add a Non-Steam Game's Browse and every
/// other picker in Steam's UI showed nothing. The call is taken on its way
/// to the client and answered with the Mac panel's choice as a Windows path
/// on the bottle's `Z:` drive, which is the whole filesystem.
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

    /// Presents the panel the options describe and answers the choice as a
    /// Windows path, or `nil` for a dismissed panel.
    static func choose(_ options: Options) async -> String? {
        let title = options.title
        let initial = options.initialFile
        let extensions = options.patterns.compactMap { pattern -> String? in
            guard pattern.hasPrefix("*."), !pattern.hasSuffix("*") else { return nil }
            return String(pattern.dropFirst(2))
        }
        let panel: NSSavePanel
        if options.saveMode {
            panel = NSSavePanel()
            panel.nameFieldStringValue = unixPath(initial).map { URL(fileURLWithPath: $0).lastPathComponent } ?? initial
            if !extensions.isEmpty {
                panel.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
            }
        } else {
            let open = NSOpenPanel()
            open.canChooseFiles = !options.chooseDirectory
            open.canChooseDirectories = options.chooseDirectory
            open.allowsMultipleSelection = false
            if !extensions.isEmpty, !extensions.contains("*") {
                open.allowedContentTypes = extensions.compactMap { UTType(filenameExtension: $0) }
                open.allowsOtherFileTypes = true
            }
            if let initial = unixPath(initial) {
                open.directoryURL = URL(fileURLWithPath: initial).deletingLastPathComponent()
            }
            panel = open
        }
        panel.title = title ?? ""
        NSApp.activate()
        // A modal session here would hold every main-actor job — the control
        // endpoint, the helper's heartbeat — for as long as the panel is up.
        let response = await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
        guard response == .OK, let chosen = panel.url else { return nil }
        EventLog.shared.log(.client, "Steam's file dialog: chose \(chosen.lastPathComponent)")
        return windowsPath(chosen.path)
    }

    /// `Z:\Users\…` for a Mac path.
    static func windowsPath(_ path: String) -> String {
        "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// The Mac path behind a `Z:` path, or `nil` for anything else.
    static func unixPath(_ windows: String) -> String? {
        guard windows.lowercased().hasPrefix("z:") else { return nil }
        return windows.dropFirst(2).replacingOccurrences(of: "\\", with: "/")
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
