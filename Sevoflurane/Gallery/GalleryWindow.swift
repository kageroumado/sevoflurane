#if DEBUG
    import AppKit
    import Propofol
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
            let host = NSHostingView(rootView: GalleryView().tiles(withWizardStates: false).frame(width: width))
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
                let panels = await writeRunPanels(to: directory, appearance: window.appearance)
                print("gallery export: \(panels) run panels in \(directory.path)")
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

        /// The first-run assistant at its window's size, each screen in each
        /// state as `setup-<number>-<screen>-<state>.png` (``WizardState``),
        /// and the popover that leads back to an unfinished setup as
        /// `setup-popover-<state>.png`.
        private static func writeWizard(to directory: URL, appearance: NSAppearance?) async -> Int {
            for state in WizardState.all + Fixtures.setupPopovers.compactMap(\.state) {
                await state.arrange()
            }
            // A run ends a few main-actor turns after the button that starts it.
            try? await Task.sleep(for: settleDelay)
            let width = SetupMetrics.windowSize.width
            // A screen of the assistant says how tall its window is once it
            // has been laid out (`layout`); a popover is as tall as its content.
            var screens: [(name: String, view: AnyView, width: CGFloat, layout: SetupLayout?)] =
                WizardState.all.map { state in
                    // The assistant is key whenever it is up; an offscreen
                    // window never is, and draws its controls as inactive.
                    let view = SetupView(store: state.store, layout: state.layout).environment(\.appearsActive, true)
                    return ("setup-\(state.id)", AnyView(view), width, state.layout)
                }
            screens += Fixtures.setupPopovers.map { entry in
                ("setup-popover-\(entry.name)", AnyView(entry.popover.view), Theme.popoverWidth + Theme.Space.md * 2, nil)
            }
            let hosts = screens.map { screen in
                // The popover's cards are glass, which an offscreen window
                // draws only as inactive, and without its buttons.
                let host = NSHostingView(rootView: screen.view
                    .frame(width: screen.width)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(
                        origin: CGPoint(x: -20000, y: -20000),
                        size: CGSize(
                            width: screen.width, height: screen.layout == nil ? probeHeight : SetupMetrics.windowSize.height,
                        ),
                    ),
                    styleMask: [.borderless], backing: .buffered, defer: false,
                )
                window.contentView = host
                if let appearance {
                    window.appearance = appearance
                    window.backgroundColor = .windowBackgroundColor
                }
                window.orderBack(nil)
                return (name: screen.name, host: host, window: window, layout: screen.layout)
            }
            try? await Task.sleep(for: settleDelay)
            for entry in hosts {
                let height = entry.layout?.windowHeight ?? entry.host.fittingSize.height
                entry.window.setContentSize(CGSize(width: entry.host.bounds.width, height: height))
                entry.host.layoutSubtreeIfNeeded()
            }
            try? await Task.sleep(for: .seconds(1))
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

        /// The panel about a run at its own size, once per cause, as
        /// `view-run-<cause>.png` (``RunDiagnosisFixtures``).
        private static func writeRunPanels(to directory: URL, appearance: NSAppearance?) async -> Int {
            let hosts = RunDiagnosisFixtures.panels.map { panel in
                // The panel is key whenever it is up; an offscreen window never is.
                let host = NSHostingView(rootView: RunDiagnosisView(model: panel.model)
                    .environment(\.appearsActive, true)
                    .background(Color(nsColor: .windowBackgroundColor)))
                let window = NSWindow(
                    contentRect: NSRect(origin: CGPoint(x: -20000, y: -20000), size: host.fittingSize),
                    styleMask: [.borderless], backing: .buffered, defer: false,
                )
                window.contentView = host
                if let appearance {
                    window.appearance = appearance
                    window.backgroundColor = .windowBackgroundColor
                }
                window.orderBack(nil)
                return (name: "view-run-\(panel.id)", host: host, window: window)
            }
            try? await Task.sleep(for: settleDelay)
            for entry in hosts {
                entry.window.setContentSize(entry.host.fittingSize)
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
