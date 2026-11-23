import SwiftUI

// MARK: - About

struct AboutSettings: View {
    let highlighted: SettingsAnchor?
    @State private var diagnosticsError: String?

    var body: some View {
        SettingsHero(
            name: "Sevoflurane", detail: String(localized: "Version \(Self.version)"), failure: diagnosticsError,
        ) {
            Link(
                "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                destination: URL(string: "https://kagerou.glass")!,
            )
            Link(
                "GitHub \(Image(systemName: "arrow.up.right"))",
                destination: URL(string: "https://github.com/kageroumado/sevoflurane")!,
            )
        } actions: {
            Button("Acknowledgments") {
                NSApp.sendAction(#selector(AppDelegate.showAcknowledgements(_:)), to: nil, from: nil)
            }
            Button("License") {
                NSApp.sendAction(#selector(AppDelegate.showLicense(_:)), to: nil, from: nil)
            }
            SaveDiagnosticsButton(error: $diagnosticsError)
                .highlightable(.aboutDiagnostics, highlighted: highlighted)
        }
        .highlightableSection(.aboutVersion, highlighted: highlighted)
    }

    private static var version: String {
        AppVersion.displayed(from: Bundle.main.infoDictionary, fallback: "dev")
    }
}
