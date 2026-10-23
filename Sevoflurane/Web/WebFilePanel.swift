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

    /// Runs `panel` as a sheet on `window` while it is on screen, and on its
    /// own otherwise. Never `runModal`: a modal session holds every main-actor
    /// job, the control endpoint and the helper's heartbeat among them, for
    /// as long as the panel is up.
    static func present(_ panel: NSSavePanel, over window: NSWindow?) async -> NSApplication.ModalResponse {
        if let window, window.isVisible, window.attachedSheet == nil {
            return await panel.beginSheetModal(for: window)
        }
        NSApp.activate()
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
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
