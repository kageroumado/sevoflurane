import SwiftUI
import WebKit

/// Hosts Apple's Game Porting Toolkit download page and installs what the user
/// downloads, without leaving the app. Used by the onboarding graphics step
/// and by Settings › Graphics.
struct GPTkDownloadPanel: View {
    /// Owned by the caller, so a download survives view re-renders and the
    /// caller can see when one is in flight (`download.isBusy`).
    let download: GPTkDownload
    /// Installs a DMG and answers a failure string; wired to `GraphicsStore`.
    let install: @MainActor (URL) async -> String?
    /// Called with each version as it lands, so the caller can refresh.
    var onInstalled: (@MainActor (String) -> Void)?

    var body: some View {
        VStack(spacing: 12) {
            instructions
            webView
            if !download.items.isEmpty { itemList }
        }
        .onAppear {
            download.install = install
            download.onInstalled = onInstalled
        }
    }

    private var instructions: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: download.autoPhase == .manual
                ? "hand.point.up.left" : "info.circle")
                .foregroundStyle(download.autoPhase == .manual ? .orange : .secondary)
            Text(download.autoPhase == .manual
                ? "The versions couldn't be picked automatically — click "
                + "Download on the release and beta you want. They still "
                + "install here by themselves."
                : "Sign in with your Apple ID; the newest release and beta "
                + "toolkits then download and install here automatically.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    private var webView: some View {
        GPTkWebViewRepresentable(webView: download.webView)
            .overlay {
                if !download.pageLoaded {
                    ProgressView().controlSize(.large)
                } else if download.autoPhase == .searching {
                    searchingOverlay
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(.quaternary),
            )
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

    private var itemList: some View {
        VStack(spacing: 6) {
            ForEach(download.items) { item in
                HStack(spacing: 10) {
                    icon(for: item.phase)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.filename).font(.callout).lineLimit(1).truncationMode(.middle)
                        caption(for: item)
                    }
                    Spacer()
                    if case .downloading = item.phase {
                        Text(percent(item.fraction))
                            .font(.callout.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(.quaternary.opacity(0.4)),
                )
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
            Text("Installed as D3DMetal \(version)").font(.caption).foregroundStyle(.secondary)
        case let .failed(reason):
            Text(reason).font(.caption).foregroundStyle(.orange).lineLimit(2)
        }
    }

    private func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }
}

/// The `WKWebView` itself, kept alive by the controller so navigation and
/// downloads survive SwiftUI re-renders.
private struct GPTkWebViewRepresentable: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context _: Context) -> WKWebView { webView }
    func updateNSView(_: WKWebView, context _: Context) {}
}
