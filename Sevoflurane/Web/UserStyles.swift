import CoreServices
import Foundation

/// The user's own stylesheets for Steam: every `.css` file in
/// `~/Library/Application Support/<installation>/Styles`, in Finder's name
/// order, joined into one stylesheet that ``SteamUserCSS`` puts on the page.
nonisolated enum UserStyles {
    /// The folder the stylesheets live in.
    static var folder: URL {
        AppIdentity.supportFolder.appending(path: "Styles", directoryHint: .isDirectory)
    }

    /// The commented sample the folder starts with.
    static let sampleName = "README.css"

    /// Every `.css` file in `folder`, in Finder's name order (`2-` before
    /// `10-`), each under a comment naming its file. Empty when the folder is
    /// missing or holds no stylesheet.
    static func stylesheet(in folder: URL = folder) -> String {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles],
        )) ?? []
        return urls
            .filter { $0.pathExtension.lowercased() == "css" }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url in
                (try? String(contentsOf: url, encoding: .utf8)).map { "/* \(url.lastPathComponent) */\n\($0)" }
            }
            .joined(separator: "\n")
    }

    /// Creates the folder, with the sample in it when it has just been made.
    static func prepareFolder(_ folder: URL = folder) throws {
        guard !FileManager.default.fileExists(atPath: folder.path) else { return }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try sample.write(to: folder.appending(path: sampleName), atomically: true, encoding: .utf8)
    }

    /// The sample stylesheet: how the folder works and which of Steam's
    /// selectors hold across client updates, all inside one comment.
    static let sample = """
    /*
      Custom style for Steam in Sevoflurane
    
      Every .css file in this folder styles Steam's windows, in name order
      (01-colors.css before 02-library.css). Saving a file restyles every open
      window within a second. Turn the style on, and choose whether it also
      styles the store and community pages, in Sevoflurane Settings >
      General > Custom style.
    
      Most of Steam's class names are hashes, such as ._3x1HklzyDs4TEjACrRO2tB,
      that change with nearly every Steam update. These selectors hold:
    
        body.DesktopUI             the main Steam window
        body.WindowFocus           a window while it is focused
        .TitleBar.title-area       a window's title strip
        .DialogButton              buttons in dialogs and settings;
                                   .DialogButton.Primary is the main one
        .DialogInput, .DialogDropDown, .DialogCheckbox, .DialogToggle_Label
                                   text fields, menus and switches
        .DialogHeader              headings in dialogs and settings
        .ModalOverlayContent       a dialog over the window
        .SVGIcon_Settings, .SVGIcon_Download, ...
                                   icons, each named for what it shows
        .avatarHolder, .avatarStatus
                                   avatars and their online ring
        [role="button"], [role="link"], [role="checkbox"], [role="listitem"]
                                   controls, by what they do
    
      Steam's desktop client defines no theme variables, so colors are set on
      these selectors directly. The store and community pages are ordinary
      websites with readable, long-lived class names (#global_header,
      .game_area_purchase_game).
    
      To find a selector, open Steam's window and use Develop > Show Web
      Inspector in Safari, with Show features for web developers turned on in
      Safari's Advanced settings.
    
      An example, left inside this comment so it does nothing:
    
      body.DesktopUI .DialogButton.Primary {
        background: #7a5cff;
      }
    */
    
    """
}

/// Calls back on the main queue when anything in a folder changes: a file
/// saved in place or atomically, added, renamed or removed.
@MainActor
final class FolderWatch {
    private let onChange: @MainActor () -> Void
    private var stream: FSEventStreamRef?

    /// `latency` is how long FSEvents gathers changes before one callback.
    init(folder: URL, latency: TimeInterval = 0.2, onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil,
        )
        let flags = kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
        guard let stream = FSEventStreamCreate(
            nil, Self.callback, &context, [folder.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, FSEventStreamCreateFlags(flags),
        ) else { return }
        FSEventStreamSetDispatchQueue(stream, .main)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    isolated deinit {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    /// Runs on the main queue the stream is scheduled on; the stream is
    /// invalidated in `deinit`, before the watch it points at goes.
    private static let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
        guard let info else { return }
        let watch = Unmanaged<FolderWatch>.fromOpaque(info).takeUnretainedValue()
        MainActor.assumeIsolated { watch.onChange() }
    }
}
