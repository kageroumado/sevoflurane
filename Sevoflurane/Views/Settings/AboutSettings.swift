import SwiftUI

// MARK: - About

struct AboutSettings: View {
    let highlighted: SettingsAnchor?
    @State private var diagnosticsError: String?

    /// In a scroll view like every other pane: the split view hangs its title
    /// bar and sidebar on the detail's scroll view, and without one the
    /// sidebar's rows sit above the window's top.
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
                .accessibilityHidden(true)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .semibold))
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
            Text(diagnosticsError
                ?? String(localized: "Diagnostics go in a ZIP on your Desktop, with your name and file paths removed."))
                .font(.callout)
                .foregroundStyle(diagnosticsError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .highlightable(.aboutVersion, highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private static var version: String {
        AppVersion.displayed(from: Bundle.main.infoDictionary, fallback: "dev")
    }
}
