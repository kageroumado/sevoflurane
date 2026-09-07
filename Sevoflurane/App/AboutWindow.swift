import AppKit
import SwiftUI

/// The About window and the two documents it opens: Acknowledgements (every
/// third-party component and data source, with its license) and the app's
/// own License. The standard About panel cannot carry either, and a Wine
/// launcher carries more third-party work than most apps, so it gets the
/// window Refrax has: icon, version, links, two buttons.
///
/// Windows are built when asked for and released when closed, the way
/// ``SettingsWindow`` does it; a window on screen gives the menu-bar app a
/// Dock tile for as long as it is up.
@MainActor
final class AboutWindows {
    private enum Kind {
        case about
        case acknowledgements
        case license
    }

    private var windows: [Kind: NSWindow] = [:]

    func showAbout() {
        show(.about) {
            let window = NSWindow(contentViewController: NSHostingController(rootView: AboutView()))
            window.title = "About Sevoflurane"
            window.styleMask = [.titled, .closable]
            window.titlebarSeparatorStyle = .none
            window.titleVisibility = .hidden
            window.isMovableByWindowBackground = true
            return window
        }
    }

    func showAcknowledgements() {
        show(.acknowledgements) {
            let view = LicenseTextView(text: Acknowledgements.text)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Acknowledgements"
            window.styleMask = [.titled, .closable, .resizable]
            window.titlebarSeparatorStyle = .none
            window.setContentSize(NSSize(width: 640, height: 520))
            window.minSize = NSSize(width: 400, height: 300)
            return window
        }
    }

    func showLicense() {
        show(.license) {
            let view = LicenseTextView(text: Acknowledgements.ownLicense)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "License"
            window.styleMask = [.titled, .closable, .resizable]
            window.titlebarSeparatorStyle = .none
            window.setContentSize(NSSize(width: 640, height: 440))
            window.minSize = NSSize(width: 400, height: 300)
            return window
        }
    }

    private func show(_ kind: Kind, make: () -> NSWindow) {
        ActivationPolicy.becomeRegular()
        if let window = windows[kind] {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }
        let window = make()
        window.isRestorable = false
        windows[kind] = window
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main,
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                self?.windows[kind] = nil
                ActivationPolicy.recedeIfLastWindow(closing: window)
            }
        }
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }
}

/// The About panel's layout: the system's proportions, with the two document
/// buttons where the standard panel has none.
struct AboutView: View {
    private static let version: String = {
        let info = Bundle.main.infoDictionary
        let marketing = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "Version \(marketing) (\(build))"
    }()

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 128, height: 128)
            VStack(alignment: .leading, spacing: 0) {
                Text("Sevoflurane")
                    .font(.system(size: 32, weight: .regular))
                Text(Self.version)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                Text("Copyright \u{00A9} 2026 kageroumado. MIT License.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 16)
                links
                    .padding(.top, 8)
                buttons
                    .padding(.top, 16)
            }
        }
        .padding(EdgeInsets(top: 28, leading: 28, bottom: 24, trailing: 28))
        .frame(width: 540)
        .fixedSize()
    }

    private var links: some View {
        HStack(spacing: 4) {
            Link(destination: URL(string: "https://github.com/kageroumado/sevoflurane")!) {
                Label("GitHub", systemImage: "link")
            }
            Text("·").foregroundStyle(.secondary)
            Link("kagerou.glass", destination: URL(string: "https://kagerou.glass")!)
            Text("·").foregroundStyle(.secondary)
            Link("@kageroumado", destination: URL(string: "https://x.com/kageroumado")!)
        }
        .font(.system(size: 11))
    }

    private var buttons: some View {
        HStack(spacing: 12) {
            Button("Acknowledgements") {
                NSApp.sendAction(#selector(AppDelegate.showAcknowledgements(_:)), to: nil, from: nil)
            }
            Button("License") {
                NSApp.sendAction(#selector(AppDelegate.showLicense(_:)), to: nil, from: nil)
            }
        }
        .controlSize(.large)
    }
}

/// A license document: monospaced, selectable, scrolling.
struct LicenseTextView: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .frame(minWidth: 400, minHeight: 300)
    }
}

/// The bundled license texts, one file per component, joined in the order
/// they are listed here: the engine and its graphics layers first, then the
/// shader packages the upscaler runs, then the Swift packages, then the data
/// sources behind the game-page strip, and the Apache text the three
/// Apache-licensed components share at the end.
enum Acknowledgements {
    static let components = [
        "wine", "liberation-fonts", "dxvk", "dxmt", "moltenvk", "d3dmetal", "nwjs",
        "anime4k", "cunny",
        "propofol", "tiptoe", "appupdater", "version", "swift-argument-parser",
        "areweanticheatyet", "applegamingwiki", "protondb",
        "apache-2.0",
    ]

    static var text: String {
        let separator = "\n\n" + String(repeating: "=", count: 72) + "\n\n"
        let sections = components.compactMap { name in
            Bundle.main.url(forResource: "license-\(name)", withExtension: "txt")
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return sections.isEmpty ? "No license texts are bundled with this build." : sections.joined(separator: separator)
    }

    static var ownLicense: String {
        Bundle.main.url(forResource: "sevoflurane-license", withExtension: "txt")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            ?? "MIT License. Copyright (c) 2026 kageroumado."
    }
}
