import AppKit
import UniformTypeIdentifiers
import WebKit

/// The Mac's open panel for a page's `<input type=file>`.
///
/// On macOS a file input shows nothing until the web view's UI delegate
/// answers `runOpenPanelWith`, so every web view hosting Steam content
/// answers it here: the UI's own windows (Set Custom Artwork, a non-Steam
/// game's icon) and the community pages beside them (a profile's avatar and
/// background, screenshot and workshop uploads).
@MainActor
enum WebFilePanel {
    /// The files the user picked for the input, or `nil` for a dismissed panel.
    static func choose(_ parameters: WKOpenPanelParameters, for webView: WKWebView) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.canChooseFiles = true
        panel.prompt = String(localized: "Choose")
        let types = contentTypes(extensions: allowedExtensions(parameters))
        if !types.isEmpty {
            panel.allowedContentTypes = types
        }
        let response = await present(panel, over: webView.window)
        return response == .OK ? panel.urls : nil
    }

    /// Runs `panel` as a sheet on the window it belongs to, and on its own
    /// when no window can take one. Never `runModal`: a modal session holds
    /// every main-actor job, the control endpoint and the helper's heartbeat
    /// among them, for as long as the panel is up.
    static func present(_ panel: NSSavePanel, over window: NSWindow?) async -> NSApplication.ModalResponse {
        if let host = sheetHost(caller: window) {
            return await panel.beginSheetModal(for: host)
        }
        // On its own the panel is a sibling of Steam's windows, and a click on
        // one of them buries it while the page still waits on its answer. It
        // floats over them instead, under Steam's menus, and steps aside while
        // another app is frontmost.
        panel.level = .modalPanel
        panel.hidesOnDeactivate = true
        NSApp.activate()
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
    }

    /// The window a sheet can hang from: the caller's own when the user can
    /// see it, else the one they are working in. Steam's UI code runs in the
    /// SharedJSContext window, which is ordered in at 0×0 and never seen, so
    /// most of its pickers arrive from there; a sheet on it is a panel stranded
    /// in the corner of the screen. Menus and the game overlay sit ordered in
    /// at alpha 0 between uses and are passed over the same way, and so is a
    /// panel already up as a sheet, which is the key window while it is.
    private static func sheetHost(caller: NSWindow?) -> NSWindow? {
        [caller, NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap(\.self).first { window in
            window.isVisible && !window.isSheet && window.alphaValue > 0 && !window.ignoresMouseEvents
                && window.frame.width > 0 && window.frame.height > 0
                && window.attachedSheet == nil
        }
    }

    /// The input's `accept` list as WebKit expands it for its own panel:
    /// MIME types (wildcards included) turned into extensions, plus HEIC
    /// wherever an image type is accepted, since WebKit transcodes those.
    private static func allowedExtensions(_ parameters: WKOpenPanelParameters) -> [String] {
        let key = "_allowedFileExtensions"
        guard parameters.responds(to: NSSelectorFromString(key)) else { return [] }
        return parameters.value(forKey: key) as? [String] ?? []
    }

    /// The panel's filter for `extensions`; empty, which lets any file
    /// through, for an input that names no type.
    nonisolated static func contentTypes(extensions: [String]) -> [UTType] {
        var types: [UTType] = []
        for name in extensions {
            let trimmed = name.hasPrefix(".") ? String(name.dropFirst()) : name
            guard !trimmed.isEmpty, let type = UTType(filenameExtension: trimmed.lowercased()),
                  !types.contains(type) else { continue }
            types.append(type)
        }
        return types
    }
}
