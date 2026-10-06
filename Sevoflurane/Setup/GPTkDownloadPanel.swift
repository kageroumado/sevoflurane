import SwiftUI
import UniformTypeIdentifiers
import WebKit

/// Gets D3DMetal onto this Mac by the user's choice of route — Apple's page
/// signed in here, their own browser with the download folders watched, or a
/// file they already have — and installs what arrives. Used by the onboarding
/// graphics step and by Settings › Graphics.
struct GPTkDownloadPanel: View {
    /// Owned by the caller, so a download survives view re-renders and the
    /// caller can see when one is in flight (`download.isBusy`).
    @Bindable var download: GPTkDownload
    /// Installs a DMG and answers a failure string; wired to `GraphicsStore`.
    let install: @MainActor (URL) async -> String?
    /// Called with each version as it lands, so the caller can refresh.
    var onInstalled: (@MainActor (String) -> Void)?
    /// Stands the web view down. A simulated run must not put Apple's real
    /// sign-in page in front of anyone: it is a live page asking for real
    /// credentials, and nothing about a demo makes that safe to show.
    var isSimulated = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Download", selection: $download.route) {
                Text("Sign In Here").tag(GPTkDownload.Route.here)
                Text("Use My Browser").tag(GPTkDownload.Route.browser)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            switch download.route {
            case .here:
                if isSimulated {
                    simulatedStandIn
                } else {
                    instructions
                    webView
                }
            case .browser:
                GPTkBrowserRoute(watch: download.folderWatch)
            }
            if !download.items.isEmpty, !coversPageWithItems { itemList }
            chooseFileRow
        }
        .onAppear {
            guard !isSimulated else { return }
            download.install = install
            download.onInstalled = onInstalled
            watch(download.route)
        }
        .onChange(of: download.route) { _, route in watch(route) }
        .onDisappear { download.folderWatch.stop() }
    }

    /// The folders are watched only while their route is on screen. A
    /// simulated run watches nothing: it has no engine to install into.
    private func watch(_ route: GPTkDownload.Route) {
        if route == .browser, !isSimulated {
            download.folderWatch.start()
        } else {
            download.folderWatch.stop()
        }
    }

    private var chooseFileRow: some View {
        HStack(spacing: 8) {
            Text("Already have the disk image?")
                .foregroundStyle(.secondary)
            Button("Choose the File…", action: chooseFile)
                .disabled(isSimulated)
            Spacer(minLength: 0)
        }
        .font(.callout)
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.message = String(localized: "Choose “Evaluation environment for Windows games” or the Game Porting Toolkit.")
        panel.allowedContentTypes = [.diskImage]
        panel.directoryURL = GPTkFolderWatch.downloads
        guard panel.runModal() == .OK, let url = panel.url else { return }
        download.installLocal(url)
    }

    /// What sits where Apple's page would be, so the step still reads as
    /// itself in a screenshot without reaching Apple.
    private var simulatedStandIn: some View {
        VStack(spacing: 8) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text("Apple's sign-in page appears here")
                .font(.callout.weight(.medium))
            Text("A real run signs in with your Apple Account and downloads the toolkit. This one loads nothing.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Whether the download cover is up with the item list as its content,
    /// so the list is drawn there and not again below.
    private var coversPageWithItems: Bool {
        download.route == .here && !isSimulated && download.pageLoaded && download.autoPhase == .downloading
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: download.autoPhase == .manual
                    ? "hand.point.up.left" : "info.circle")
                    .foregroundStyle(download.autoPhase == .manual ? .orange : .secondary)
                    .accessibilityHidden(true)
                hint
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            if download.stoppedEnrollment {
                Label("The paid program isn\u{2019}t needed. The free account is enough.", systemImage: "checkmark.seal")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.tint)
            }
        }
    }

    /// The sign-in hint, or in the manual fallback the row to click, named as
    /// Apple's page names it.
    private var hint: Text {
        guard download.autoPhase == .manual else {
            return Text("Sign in with any Apple Account, and accept Apple\u{2019}s free developer agreement if it asks. The paid Developer Program isn\u{2019}t needed. Sevoflurane picks the right download and installs it here.")
        }
        if let candidate = download.manualCandidate {
            return Text("Click Download on \u{201C}\(candidate)\u{201D}, outlined below. It installs here when its download ends.")
        }
        return Text("Click Download on \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer. It installs here when its download ends.")
    }

    private var webView: some View {
        GPTkWebViewRepresentable(webView: download.webView)
            .overlay {
                if !download.pageLoaded {
                    ProgressView().controlSize(.large)
                } else if download.autoPhase == .searching {
                    searchingOverlay
                } else if download.autoPhase == .downloading {
                    downloadCover
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary)
            }
    }

    /// Covers the download table while versions are being chosen, so the
    /// signed-in moment reads as "working", never "now what do I click".
    private var searchingOverlay: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 10) {
                ProgressView().controlSize(.large)
                Text("Finding the latest versions…")
                    .font(.callout.weight(.medium))
            }
        }
    }

    /// Covers the page from the picks until the downloads have installed:
    /// what was picked, and its progress. The page comes back only when a
    /// download failed and the user asks for it.
    private var downloadCover: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            VStack(spacing: 14) {
                coverTitle
                    .font(.callout.weight(.medium))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                itemList
                    .frame(maxWidth: 380)
                if hasFailure, !download.isBusy {
                    Button("Show Apple\u{2019}s Page") { download.showPage() }
                }
            }
            .padding(24)
        }
    }

    private var hasFailure: Bool {
        download.items.contains { $0.phase.isFailure }
    }

    private var coverTitle: Text {
        let versions = download.pickedVersions.formatted(.list(type: .and))
        if download.isBusy {
            return Text("Downloading D3DMetal \(versions), nothing to click")
        }
        if hasFailure {
            return Text("A download stopped. Its reason is below.")
        }
        return Text("D3DMetal \(versions) installed")
    }

    private var itemList: some View {
        VStack(spacing: 6) {
            ForEach(download.items) { item in
                HStack(spacing: 10) {
                    icon(for: item.phase)
                        .frame(width: 18)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.callout).lineLimit(1).truncationMode(.middle)
                        caption(for: item)
                    }
                    Spacer()
                    if case .downloading = item.phase {
                        Text(item.fraction, format: .percent.precision(.fractionLength(0)))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }

    @ViewBuilder
    private func icon(for phase: GPTkDownload.Item.Phase) -> some View {
        switch phase {
        case .downloading: ProgressView().controlSize(.small)
        case .installing: ProgressView().controlSize(.small)
        case .installed: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        }
    }

    @ViewBuilder
    private func caption(for item: GPTkDownload.Item) -> some View {
        switch item.phase {
        case .downloading:
            ProgressView(value: item.fraction).frame(maxWidth: 220)
        case .installing:
            Text("Installing…").font(.caption).foregroundStyle(.secondary)
        case let .installed(version):
            Text(InterfaceCopy.localized(version.contains("beta") ? "Installed · beta" : "Installed"))
                .font(.caption).foregroundStyle(.secondary)
        case let .failed(reason):
            Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
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

/// The route through the user's own browser: the page opens there, and the
/// folders it saves into are watched, visibly, until the image lands.
private struct GPTkBrowserRoute: View {
    let watch: GPTkFolderWatch

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                Text("Sign in on Apple\u{2019}s page with any Apple Account and download \u{201C}Evaluation environment for Windows games 4.0 beta 2\u{201D} or newer, the small file with D3DMetal in it. Sevoflurane installs it the moment it lands.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Open Apple\u{2019}s Download Page") {
                NSWorkspace.shared.open(GPTkDownload.pageURL)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if watch.isWatching { ProgressView().controlSize(.small) }
                    Text(InterfaceCopy.localized(watch.isWatching ? "Watching for the download in" : "Watching is paused"))
                        .font(.callout.weight(.medium))
                }
                ForEach(watch.folders, id: \.self) { folder in
                    HStack(spacing: 6) {
                        Image(systemName: "folder").foregroundStyle(.secondary)
                        Text((folder.path as NSString).abbreviatingWithTildeInPath)
                            .font(.callout)
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
                    .font(.callout)
                    .help("For a browser that saves somewhere other than Downloads")
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
