import SwiftUI

// MARK: - About

struct AboutSettings: View {
    let highlighted: SettingsAnchor?
    @State private var diagnosticsError: String?

    /// A scroll view like every other pane: the split view hangs its title
    /// bar and its sidebar on the detail's scroll view, and a detail without
    /// one leaves the sidebar's rows above the top of the window.
    var body: some View {
        ScrollView {
            card
                .containerRelativeFrame(.vertical, alignment: .center)
        }
    }

    private var card: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .bold))
            Text("Version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(
                    "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://kagerou.glass")!,
                )
                Link(
                    "GitHub \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://github.com/kageroumado/sevoflurane")!,
                )
            }
            .font(.system(size: 12))
            HStack(spacing: 10) {
                Button("Acknowledgments") {
                    NSApp.sendAction(#selector(AppDelegate.showAcknowledgements(_:)), to: nil, from: nil)
                }
                Button("License") {
                    NSApp.sendAction(#selector(AppDelegate.showLicense(_:)), to: nil, from: nil)
                }
                SaveDiagnosticsButton(title: "Save Diagnostics…", error: $diagnosticsError)
                    .highlightable(.aboutDiagnostics, highlighted: highlighted)
            }
            .controlSize(.small)
            .padding(.top, 6)
            Text("Saves logs, system details, and recent crashes to a ZIP on your Desktop, with your name, paths and Steam ids taken out.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
            if let diagnosticsError {
                Text(diagnosticsError).font(.caption).foregroundStyle(.red)
            }
        }
        .highlightable(.aboutVersion, highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
