import Foundation
import Testing
import UniformTypeIdentifiers
import WebKit
@testable import Sevoflurane

/// Every way Steam asks for a file: an HTML file input in one of the web
/// views, and the client's own `OpenFileDialog`. A picker nothing answers
/// shows nothing at all.
@MainActor
struct FilePickerTests {
    /// The selector WebKit asks the UI delegate about. A Swift method written
    /// with a plain closure binds none, and the click then does nothing.
    private static let openPanel = NSSelectorFromString(
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
    )

    @Test
    func `every web view's UI delegate answers file inputs`() {
        #expect(SteamWebCoordinator.instancesRespond(to: Self.openPanel))
        #expect(BrowserViewChild.instancesRespond(to: Self.openPanel))
    }

    @Test
    func `an input's accepted extensions become the panel's types`() {
        let types = WebFilePanel.contentTypes(extensions: ["jpg", ".PNG", "jpeg", "png"])
        #expect(types.contains(.jpeg))
        #expect(types.contains(.png))
        #expect(types.count == 2)
    }

    @Test
    func `an input that names no type takes any file`() {
        #expect(WebFilePanel.contentTypes(extensions: []).isEmpty)
        #expect(WebFilePanel.contentTypes(extensions: ["", "."]).isEmpty)
    }

    @Test
    func `Steam's patterns filter the panel`() {
        let types = SteamFileDialogs.contentTypes(patterns: ["*.tga", "*.png"])
        #expect(types.contains(.png))
        #expect(types.contains { $0.preferredFilenameExtension == "tga" })
    }

    @Test
    func `All files lifts the filter`() {
        #expect(SteamFileDialogs.contentTypes(patterns: ["*.exe", "*.*"]).isEmpty)
        #expect(SteamFileDialogs.contentTypes(patterns: []).isEmpty)
    }

    @Test
    func `a save panel is named after the suggested file`() {
        #expect(SteamFileDialogs.fileName(#"C:\Users\steamuser\Videos\clip.mp4"#) == "clip.mp4")
        #expect(SteamFileDialogs.fileName("clip.mp4") == "clip.mp4")
        #expect(SteamFileDialogs.fileName("") == "")
    }

    @Test
    func `the dialog's options come off the call's argument`() {
        let options = SteamFileDialogs.Options([
            "strTitle": "Choose a folder",
            "strInitialFile": #"C:\Program Files (x86)\Steam"#,
            "bChooseDirectory": true,
            "rgFilters": [["strFileTypeName": "Images", "rFilePatterns": ["*.png", "*.jpg"]]],
        ])
        #expect(options.title == "Choose a folder")
        #expect(options.chooseDirectory)
        #expect(!options.saveMode)
        #expect(options.patterns == ["*.png", "*.jpg"])
    }
}
