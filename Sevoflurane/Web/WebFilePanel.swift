import AppKit
import UniformTypeIdentifiers
import WebKit

/// The Mac's open panel for a page's `<input type=file>`.
///
/// A file input shows nothing until the UI delegate answers
/// `runOpenPanelWith`; every web view hosting Steam content answers it here.
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

    /// Runs `panel` as a sheet, or on its own when no window can take one.
    /// Never `runModal`: it holds every main-actor job, the control endpoint
    /// and the helper's heartbeat included, while the panel is up.
    static func present(_ panel: NSSavePanel, over window: NSWindow?) async -> NSApplication.ModalResponse {
        if let host = sheetHost(caller: window) {
            return await panel.beginSheetModal(for: host)
        }
        // Floats over Steam's windows (a click on one would bury it), under
        // its menus, and hides while another app is frontmost.
        panel.level = .modalPanel
        panel.hidesOnDeactivate = true
        NSApp.activate()
        return await withCheckedContinuation { continuation in
            panel.begin { continuation.resume(returning: $0) }
        }
    }

    /// The window a sheet can hang from: the caller's if visible, else the
    /// key or main window. Most pickers come from the 0×0 SharedJSContext
    /// window; it, alpha-0 menus and overlays, and windows already showing a
    /// sheet are passed over.
    private static func sheetHost(caller: NSWindow?) -> NSWindow? {
        [caller, NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap(\.self).first { window in
            window.isVisible && !window.isSheet && window.alphaValue > 0 && !window.ignoresMouseEvents
                && window.frame.width > 0 && window.frame.height > 0
                && window.attachedSheet == nil
        }
    }

    /// The input's `accept` list as WebKit expands it: MIME types (wildcards
    /// included) as extensions, plus HEIC for images, which WebKit transcodes.
    private static func allowedExtensions(_ parameters: WKOpenPanelParameters) -> [String] {
        let key = "_allowedFileExtensions"
        guard parameters.responds(to: NSSelectorFromString(key)) else { return [] }
        return parameters.value(forKey: key) as? [String] ?? []
    }

    /// The panel's filter for `extensions`; empty lets any file through.
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
