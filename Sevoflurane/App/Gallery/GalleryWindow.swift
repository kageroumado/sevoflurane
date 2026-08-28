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
#endif
