#if DEBUG
    import AppKit
    import SwiftUI

    /// The window ``GalleryView`` lives in.
    @MainActor
    final class GalleryWindow: NSObject {
        private var window: NSWindow?

        /// Whether the process was launched to be the gallery and nothing
        /// else — `-SEVO_GALLERY 1` as a scheme argument, or `SEVO_GALLERY=1`
        /// in the environment.
        static var wasRequestedAtLaunch: Bool {
            ProcessInfo.processInfo.environment["SEVO_GALLERY"] == "1"
                || UserDefaults.standard.bool(forKey: "SEVO_GALLERY")
        }

        func show() {
            if let directory = GalleryExport.requestedDirectory {
                GalleryExport.run(to: directory)
                return
            }
            if let window {
                window.makeKeyAndOrderFront(nil)
                NSApp.activate()
                return
            }
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: GalleryView()),
            )
            window.title = "UI Gallery"
            window.styleMask = [.titled, .closable, .resizable]
            window.setContentSize(NSSize(width: 1320, height: 900))
            window.isRestorable = false
            window.center()
            self.window = window
            // Promotion from `.accessory` lands a run loop turn later, and a
            // window ordered front in the same pass is swallowed with it —
            // the same trap `SteamWindow.show` documents.
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate()
            }
        }
    }

    /// The gallery written to disk as PNG strips, for a visual pass that needs
    /// no one to scroll a window: `SEVO_GALLERY_EXPORT=<directory>` beside
    /// `SEVO_GALLERY=1`, in the dark appearance with
    /// `SEVO_GALLERY_APPEARANCE=dark`. The process quits when the last strip
    /// is written.
    @MainActor
    enum GalleryExport {
        private static let width: CGFloat = 1320
        private static let stripHeight: CGFloat = 1100
        /// Long enough for the fixtures' artwork and the panes' first async
        /// loads to land before the picture is taken.
        private static let settleDelay: Duration = .seconds(3)
        private static var window: NSWindow?

        static var requestedDirectory: URL? {
            guard let path = ProcessInfo.processInfo.environment["SEVO_GALLERY_EXPORT"], !path.isEmpty
            else { return nil }
            return URL(fileURLWithPath: path, isDirectory: true)
        }

        static func run(to directory: URL) {
            let host = NSHostingView(rootView: GalleryView().tiles.frame(width: width))
            let window = NSWindow(
                contentRect: NSRect(x: -20000, y: -20000, width: width, height: stripHeight),
                styleMask: [.borderless], backing: .buffered, defer: false,
            )
            window.contentView = host
            if ProcessInfo.processInfo.environment["SEVO_GALLERY_APPEARANCE"] == "dark" {
                window.appearance = NSAppearance(named: .darkAqua)
                window.backgroundColor = .windowBackgroundColor
            }
            window.orderBack(nil)
            self.window = window
            Task(name: "Gallery export") {
                try? await Task.sleep(for: settleDelay)
                let height = host.fittingSize.height
                window.setContentSize(NSSize(width: width, height: height))
                host.layoutSubtreeIfNeeded()
                try? await Task.sleep(for: settleDelay)
                try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                var strip = 0
                // A hosting view is flipped: y 0 is the top of the gallery.
                var top: CGFloat = 0
                while top < height {
                    let rect = NSRect(x: 0, y: top, width: width, height: min(stripHeight, height - top))
                    if let bitmap = host.bitmapImageRepForCachingDisplay(in: rect) {
                        host.cacheDisplay(in: rect, to: bitmap)
                        let name = String(format: "gallery-%02d.png", strip)
                        try? bitmap.representation(using: .png, properties: [:])?
                            .write(to: directory.appendingPathComponent(name))
                    }
                    strip += 1
                    top += stripHeight
                }
                print("gallery export: \(strip) strips of \(Int(height)) pt in \(directory.path)")
                NSApp.terminate(nil)
            }
        }
    }
#endif
