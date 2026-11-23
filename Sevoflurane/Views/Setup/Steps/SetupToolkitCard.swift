import Propofol
import SwiftUI

/// The DirectX 12 offer, asked while Steam installs: what the player gets,
/// what it is, why Apple asks for a sign-in. "Sign In to Apple" brings up
/// Apple's own page with its host over it; the player's browser is the other
/// way. Declining is the screen's "Not Now".
struct SetupToolkitCard: View {
    let store: SetupStore

    /// The first run's one name for what Apple's page gives.
    private static let product = "Game Porting Toolkit"

    private var download: GPTkDownload {
        store.toolkit
    }

    var body: some View {
        SetupList {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Newer games (DirectX 12)")
                    .font(SettingsType.heading)
                // The offer is read before Apple's page is asked for; with
                // the page up, the room is the page's.
                if !store.toolkitIsOpen {
                    Text("They need Apple\u{2019}s Game Porting Toolkit, a free download from Apple. Apple asks you to sign in with an Apple Account to download it. The sign-in page is Apple\u{2019}s, and Sevoflurane never sees your password.")
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Later: Settings \u{203A} Graphics.")
                        .font(SettingsType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if store.toolkitIsOpen {
                route
            } else {
                SettingsRow(title: "Rather use your own browser?") {
                    Button("Use My Browser") { store.useBrowserForToolkit() }
                }
            }
        }
        .onAppear { download.isOnScreen = true }
        .onDisappear { download.isOnScreen = false }
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
                    GPTkApplePage(download: download, product: Self.product)
                        .frame(height: SetupMetrics.applePageHeight)
                } else {
                    GPTkSimulatedPage()
                }
                if !download.items.isEmpty, !download.coversPageWithItems {
                    GPTkItemList(download: download, product: Self.product)
                }
            }
        case .browser:
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                GPTkBrowserRoute(
                    watch: download.folderWatch,
                    instruction: "Sign in on Apple\u{2019}s page with any Apple Account and download \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer. Sevoflurane installs it the moment it lands.",
                )
                if !download.items.isEmpty {
                    GPTkItemList(download: download, product: Self.product)
                }
            }
        }
    }
}
