import Propofol
import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Gets D3DMetal onto this Mac through Apple's page signed in here, the
/// user's own browser with the download folders watched, or a file they
/// already have: the sheet of Settings › Graphics. The first-run assistant
/// builds its own card from the same pieces (``SetupToolkitCard``).
struct GPTkDownloadPanel: View {
    /// Owned by the graphics store, so a download survives this view.
    @Bindable var download: GPTkDownload

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Picker("Download", selection: $download.route) {
                Text("Sign In Here").tag(GPTkDownload.Route.here)
                Text("Use My Browser").tag(GPTkDownload.Route.browser)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch download.route {
            case .here:
                if download.showsApplePage {
                    GPTkSignInHint(download: download)
                    GPTkApplePage(download: download)
                } else {
                    GPTkSimulatedPage()
                }
            case .browser:
                GPTkBrowserRoute(watch: download.folderWatch)
            }
            if !download.items.isEmpty, !download.coversPageWithItems {
                GPTkItemList(download: download)
            }
            chooseFileRow
        }
        .onAppear { download.isOnScreen = true }
        .onDisappear { download.isOnScreen = false }
    }

    private var chooseFileRow: some View {
        HStack(spacing: Theme.Space.sm) {
            Text("Already have the disk image?")
                .foregroundStyle(.secondary)
            Button("Choose the File…") {
                if let image = ToolkitImagePanel.choose() { download.installLocal(image) }
            }
            .disabled(!download.loadsApplePage)
            Spacer(minLength: 0)
        }
        .font(SettingsType.caption)
    }
}

extension GPTkDownload {
    /// Whether the download cover is up with the item list as its content,
    /// so the list is drawn there and not again beside the page.
    var coversPageWithItems: Bool {
        route == .here && showsApplePage && pageLoaded && autoPhase == .downloading
    }
}

/// Stands in for Apple's page in a simulated run.
struct GPTkSimulatedPage: View {
    var body: some View {
        VStack(spacing: Theme.Space.sm) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("Apple's sign-in page appears here")
                .font(SettingsType.caption.weight(.medium))
            Text("A real run signs in with your Apple Account and downloads the toolkit. This one loads nothing.")
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(Theme.Space.xl)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: GPTkMetrics.radius, style: .continuous))
    }
}

/// The sizes the toolkit download's pieces share.
enum GPTkMetrics {
    static let radius: CGFloat = 10
    static let itemRadius: CGFloat = 8
    static let coverWidth: CGFloat = 380
    /// Settings names the part of Apple's toolkit it installs.
    static let settingsProduct = "D3DMetal"
}

/// The sign-in hint, or in the manual fallback the row to click, named as
/// Apple's page names it.
struct GPTkSignInHint: View {
    let download: GPTkDownload

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            if download.autoPhase == .manual {
                SettingsStatus(.warning, manualHint)
            } else {
                Text("Sign in with any Apple Account, and accept Apple\u{2019}s free developer agreement if it asks. The paid Developer Program isn\u{2019}t needed. Sevoflurane picks the right download and installs it here.")
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if download.stoppedEnrollment {
                SettingsStatus(.done, String(localized: "The paid program isn\u{2019}t needed. The free account is enough."))
            }
        }
    }

    private var manualHint: String {
        if let candidate = download.manualCandidate {
            return String(localized: "Click Download on \u{201C}\(candidate)\u{201D}, outlined below. It installs here when its download ends.")
        }
        return String(localized: "Click Download on \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer. It installs here when its download ends.")
    }
}

/// Apple's page in a web view, covered while versions are chosen and while
/// they download.
struct GPTkApplePage: View {
    let download: GPTkDownload
    /// What the surface calls the thing being downloaded.
    var product = GPTkMetrics.settingsProduct

    var body: some View {
        page
            .overlay {
                if !download.pageLoaded {
                    ProgressView().controlSize(.large)
                } else if download.autoPhase == .searching {
                    searchingOverlay
                } else if download.autoPhase == .downloading {
                    downloadCover
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: GPTkMetrics.radius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: GPTkMetrics.radius, style: .continuous)
                    .strokeBorder(.quaternary)
            }
    }

    /// Apple's page, or in the gallery the stand-in for it.
    @ViewBuilder private var page: some View {
        #if DEBUG
            if download.isStaged {
                GPTkStagedPage()
            } else {
                GPTkWebViewRepresentable(webView: download.webView)
            }
        #else
            GPTkWebViewRepresentable(webView: download.webView)
        #endif
    }

    /// Covers the download table while versions are being chosen.
    private var searchingOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            SettingsStatus(.working, String(localized: "Finding the latest versions…"))
        }
    }

    /// Covers the page with the picks and their progress until they install.
    /// The page comes back only when a download failed and the user asks.
    private var downloadCover: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: Theme.Space.md) {
                coverTitle
                    .font(SettingsType.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                GPTkItemList(download: download, product: product)
                    .frame(maxWidth: GPTkMetrics.coverWidth)
                if hasFailure, !download.isBusy {
                    Button("Show Apple\u{2019}s Page") { download.showPage() }
                }
            }
            .padding(Theme.Space.xl)
        }
    }

    private var hasFailure: Bool {
        download.items.contains { $0.phase.isFailure }
    }

    private var coverTitle: Text {
        let versions = download.pickedVersions.formatted(.list(type: .and))
        if download.isBusy {
            return Text("Downloading \(product) \(versions), nothing to click")
        }
        if hasFailure {
            return Text("A download stopped. Its reason is below.")
        }
        return Text("\(product) \(versions) installed")
    }
}

/// Each toolkit download with where it stands: a bar and a fraction in
/// digits while it downloads, then installing, installed or why it failed.
struct GPTkItemList: View {
    let download: GPTkDownload
    /// What the surface calls the thing being downloaded.
    var product = GPTkMetrics.settingsProduct

    var body: some View {
        VStack(spacing: Theme.Space.xs) {
            ForEach(download.items) { item in
                VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
                    HStack(spacing: Theme.Space.sm) {
                        Text(verbatim: GPTkDownload.version(inFilename: item.filename).map { "\(product) \($0)" } ?? item.filename)
                            .font(SettingsType.title)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: Theme.Space.sm)
                        if case .downloading = item.phase {
                            ProgressView(value: item.fraction)
                                .frame(width: SettingsMetrics.progressWidth)
                            Text(item.fraction, format: .percent.precision(.fractionLength(0)))
                                .font(SettingsType.value)
                                .foregroundStyle(.secondary)
                        }
                    }
                    state(of: item)
                }
                .padding(Theme.Space.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    .quaternary.opacity(0.4),
                    in: RoundedRectangle(cornerRadius: GPTkMetrics.itemRadius, style: .continuous),
                )
            }
        }
    }

    @ViewBuilder
    private func state(of item: GPTkDownload.Item) -> some View {
        switch item.phase {
        case .downloading:
            EmptyView()
        case .installing:
            SettingsStatus(.working, String(localized: "Installing…"))
        case let .installed(version):
            SettingsStatus(.done, InterfaceCopy.localized(version.contains("beta") ? "Installed · beta" : "Installed"))
        case let .failed(reason):
            SettingsStatus(.failure, SetupFailureText.asSentence(reason))
        }
    }
}

/// The `WKWebView` itself, kept alive by the controller so navigation and
/// downloads survive SwiftUI re-renders.
private struct GPTkWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> WKWebView { webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}

#if DEBUG
    /// Fills the room Apple's page takes, for a download the gallery staged:
    /// the live page needs the network and an Apple Account.
    private struct GPTkStagedPage: View {
        var body: some View {
            // The label sits at the top, clear of the covers drawn over the
            // page's middle: a material lets it show through.
            ZStack(alignment: .top) {
                Color(nsColor: .textBackgroundColor)
                Text(verbatim: "Apple’s page: developer.apple.com/download")
                    .font(.callout)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 24)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
#endif

/// The route through the user's own browser: the page opens there, and the
/// folders it saves into are watched, visibly, until the image lands.
struct GPTkBrowserRoute: View {
    let watch: GPTkFolderWatch
    /// What to do on Apple's page, in the surface's own words for the toolkit.
    var instruction: LocalizedStringResource =
        "Sign in on Apple\u{2019}s page with any Apple Account and download \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer, the small file with D3DMetal in it. Sevoflurane installs it the moment it lands."

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(instruction)
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open Apple\u{2019}s Download Page") {
                NSWorkspace.shared.open(GPTkDownload.pageURL)
            }
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                if watch.isWatching {
                    SettingsStatus(.working, String(localized: "Watching for the download in"))
                } else {
                    Text("Watching is paused")
                        .font(SettingsType.status)
                }
                ForEach(watch.folders, id: \.self) { folder in
                    HStack(spacing: Theme.Space.xs) {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(SettingsType.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 0)
                        if watch.isRemovable(folder) {
                            Button("Stop watching this folder", systemImage: "xmark.circle.fill") {
                                watch.remove(folder)
                            }
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tertiary)
                            .buttonStyle(.plain)
                            .help("Stop watching this folder")
                        }
                    }
                }
                Button("Add a Folder\u{2026}", action: addFolder)
                    .font(SettingsType.caption)
                    .help("For a browser that saves somewhere other than Downloads")
            }
            .padding(Theme.Space.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: GPTkMetrics.radius, style: .continuous))
        }
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose the folder your browser saves downloads into.")
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        watch.add(url)
    }
}

/// The open panel for a toolkit disk image, shared by Apple's download sheet
/// and Settings › Graphics so both ask for the same thing in the same words.
@MainActor
enum ToolkitImagePanel {
    /// Runs the panel and returns the chosen image, or `nil` when it was
    /// dismissed.
    static func choose() -> URL? {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose “Evaluation environment for Windows games” or the Game Porting Toolkit.")
        panel.allowedContentTypes = [.diskImage]
        // An image already opened is a folder, and it installs as well.
        panel.canChooseDirectories = true
        panel.directoryURL = GPTkFolderWatch.downloads
        return panel.runModal() == .OK ? panel.url : nil
    }
}
