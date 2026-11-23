#if DEBUG
    import AppKit
    import SwiftUI

    /// The window ``GalleryView`` lives in.
    @MainActor
    final class GalleryWindow: NSObject {
        private var window: NSWindow?

        /// Whether the process was launched as the gallery alone:
        /// `-SEVO_GALLERY 1` or `SEVO_GALLERY=1`.
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
            // Promotion from `.accessory` lands a run-loop turn later and
            // swallows a window ordered front in the same pass (the trap
            // `SteamWindow.show` documents).
            NSApp.setActivationPolicy(.regular)
            DispatchQueue.main.async {
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                NSApp.activate()
            }
        }
    }

    /// The gallery written to disk as PNG strips:
    /// `SEVO_GALLERY_EXPORT=<directory>` beside `SEVO_GALLERY=1`, dark with
    /// `SEVO_GALLERY_APPEARANCE=dark`. The process quits after the last strip.
    @MainActor
    enum GalleryExport {
        private static let width: CGFloat = 1320
        private static let stripHeight: CGFloat = 1100
        /// Long enough for the fixtures' artwork and the panes' first async
        /// loads to land.
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
                let panes = await writePanes(to: directory, appearance: window.appearance)
                print("gallery export: \(panes) panes in \(directory.path)")
                let steps = await writeWizard(to: directory, appearance: window.appearance)
                print("gallery export: \(steps) first-run screens in \(directory.path)")
                NSApp.terminate(nil)
            }
        }

        /// The height a pane's window starts at, under any pane's content, so
        /// each scroll view reports its content's own height.
        private static let probeHeight: CGFloat = 120

        /// Each Settings pane as `pane-<name>.png`: the real window's detail
        /// width and the pane's whole height, so a row can be measured in the
        /// column it is read in. A popover's content, or a pane in a window
        /// shorter than itself, is `view-<name>.png`.
        private static func writePanes(to directory: URL, appearance: NSAppearance?) async -> Int {
            let width = GalleryView.detailWidth
            let hosts = GalleryView.settingsPanes.map { pane in
                let host = NSHostingView(rootView: pane.view.background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(x: -20000, y: -20000, width: width, height: pane.fixedHeight ?? probeHeight),
                    styleMask: [.borderless], backing: .buffered, defer: false,
                )
                window.contentView = host
                if let appearance {
                    window.appearance = appearance
                    window.backgroundColor = .windowBackgroundColor
                }
                window.orderBack(nil)
                return (pane: pane, host: host, window: window)
            }
            try? await Task.sleep(for: settleDelay)
            for entry in hosts where entry.pane.fixedHeight == nil {
                let height = scrollViews(in: entry.host).compactMap { $0.documentView?.frame.height }.max()
                entry.window.setContentSize(NSSize(width: width, height: height ?? probeHeight))
                entry.host.layoutSubtreeIfNeeded()
            }
            try? await Task.sleep(for: settleDelay)
            for entry in hosts {
                let rect = entry.host.bounds
                guard let bitmap = entry.host.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                entry.host.cacheDisplay(in: rect, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent(
                        "\(entry.pane.isWholePane ? "pane" : "view")-\(entry.pane.id).png",
                    ))
            }
            return hosts.count
        }

        /// The first-run assistant at its window's size: each step as
        /// `setup-<step>.png` on a machine that reaches it.
        private static func writeWizard(to directory: URL, appearance: NSAppearance?) async -> Int {
            let screens: [(name: String, store: SetupStore)] =
                Fixtures.wizardSteps.map { ("setup-\($0.step.rawValue)", $0.store) }
            let hosts = screens.map { screen in
                let host = NSHostingView(rootView: SetupView(store: screen.store, onFinished: {})
                    .frame(width: SetupMetrics.windowSize.width, height: SetupMetrics.windowSize.height)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: SetupMetrics.windowSize),
                    styleMask: [.borderless], backing: .buffered, defer: false,
                )
                window.contentView = host
                if let appearance {
                    window.appearance = appearance
                    window.backgroundColor = .windowBackgroundColor
                }
                window.orderBack(nil)
                return (name: screen.name, host: host, window: window)
            }
            try? await Task.sleep(for: settleDelay)
            for entry in hosts {
                entry.host.layoutSubtreeIfNeeded()
                let rect = entry.host.bounds
                guard let bitmap = entry.host.bitmapImageRepForCachingDisplay(in: rect) else { continue }
                entry.host.cacheDisplay(in: rect, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?
                    .write(to: directory.appendingPathComponent("\(entry.name).png"))
            }
            return hosts.count
        }

        private static func scrollViews(in view: NSView) -> [NSScrollView] {
            view.subviews.flatMap { subview in
                (subview as? NSScrollView).map { [$0] } ?? scrollViews(in: subview)
            }
        }
    }
#endif
