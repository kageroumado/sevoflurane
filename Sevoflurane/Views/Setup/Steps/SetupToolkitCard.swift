import Propofol
import SwiftUI

/// The DirectX 12 offer, asked while Steam installs: what the player gets,
/// what it is, why Apple asks for a sign-in. "Sign In to Apple" brings up
/// Apple's own page with its host over it; the player's browser is the other
/// way. Once a download runs, the card gives way to one status row
/// (``SetupToolkitStatus``); a download that failed brings it back with the
/// reason. Declining is the screen's "Not Now".
struct SetupToolkitCard: View {
    let store: SetupStore
    @Environment(SetupLayout.self) private var layout

    private var download: GPTkDownload {
        store.toolkit
    }

    var body: some View {
        SetupList {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Newer games (DirectX 12)")
                    .font(SettingsType.heading)
                if !download.failedItems.isEmpty {
                    failures
                } else if !store.toolkitIsOpen {
                    // The offer is read before Apple's page is asked for; with
                    // the page up, the room is the page's.
                    Text("They need Apple\u{2019}s Game Porting Toolkit, a free download from Apple. Apple asks you to sign in with an Apple Account to download it. Apple\u{2019}s own page asks for it, and Sevoflurane never sees your password.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Later: Settings \u{203A} Graphics.")
                        .font(SettingsType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if download.failedItems.isEmpty {
                if store.toolkitIsOpen {
                    route
                } else {
                    Button("Use My Browser") { store.useBrowserForToolkit() }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
        }
        .onAppear { download.isOnScreen = true }
        .onDisappear { download.isOnScreen = false }
    }

    /// Each download that failed, with its reason, and what the versions
    /// that did install are good for meanwhile.
    @ViewBuilder private var failures: some View {
        ForEach(download.failedItems) { item in
            if case let .failed(reason) = item.phase {
                SettingsStatus(.failure, String(localized: "\(Self.name(of: item)) did not download: \(Self.lowercasedFirst(reason))"))
            }
        }
        let installed = download.items.compactMap { item -> String? in
            if case let .installed(version) = item.phase { version } else { nil }
        }
        if !installed.isEmpty {
            Text("\(installed.formatted(.list(type: .and))) is installed. Games that need the newer version wait for this one.")
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private static func name(of item: GPTkDownload.Item) -> String {
        GPTkDownload.version(inFilename: item.filename).map { "Game Porting Toolkit \($0)" } ?? item.filename
    }

    /// A reason that follows a colon starts in lowercase.
    private static func lowercasedFirst(_ text: String) -> String {
        let lowered = text.prefix(1).lowercased() + text.dropFirst()
        return lowered.hasSuffix(".") ? lowered : lowered + "."
    }

    @ViewBuilder private var route: some View {
        switch download.route {
        case .here:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                if download.showsApplePage {
                    HStack(spacing: Theme.Space.xs) {
                        Label(download.pageHost ?? "developer.apple.com", systemImage: "lock.fill")
                            .font(SettingsType.code)
                        Spacer(minLength: Theme.Space.sm)
                        Button("Use My Browser") { store.useBrowserForToolkit() }
                    }
                    GPTkSignInHint(download: download)
                    GPTkApplePage(download: download)
                        .frame(height: layout.applePageHeight)
                } else {
                    GPTkSimulatedPage()
                }
            }
        case .browser:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Sign in on Apple\u{2019}s page with any Apple Account and download \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer, Apple\u{2019}s name for the toolkit.")
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Open Apple\u{2019}s Download Page") {
                    NSWorkspace.shared.open(GPTkDownload.pageURL)
                }
                SettingsStatus(.working, String(localized: "Waiting for the download in your Downloads folder."))
                Button("Saved it somewhere else?") {
                    if let image = ToolkitImagePanel.choose() { download.installLocal(image) }
                }
                .buttonStyle(.link)
                .font(SettingsType.caption)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
