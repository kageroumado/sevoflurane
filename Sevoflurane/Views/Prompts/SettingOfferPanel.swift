import AppKit
import Propofol
import SwiftUI

/// An offer to change one setting of a game after a run showed it would
/// help: what it says, and its three answers.
@MainActor
struct SettingOffer {
    /// The SF Symbol beside the title.
    let symbol: String
    let title: String
    /// The run the offer is about, in one line.
    let summary: String
    let message: String
    /// When the change applies and where to find it afterwards.
    let footnote: String
    let acceptTitle: String
    let accept: () -> Void
    let notNow: () -> Void
    let stopAsking: () -> Void
}

/// The floating panel an offer is shown in, like ``CrashPrompt``'s, since a
/// menu-bar agent may have no other window. Each kind of offer keeps its own.
@MainActor
final class SettingOfferPanel: NSObject, NSWindowDelegate {
    private var panel: NSPanel?
    private var offer: SettingOffer?

    func present(_ offer: SettingOffer) {
        self.offer = offer
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: SettingOfferView(offer: offer))
        panel.setContentSize(panel.contentView?.fittingSize ?? Self.panelSize)
        panel.center()
        // Otherwise the agent app's panel opens behind the front app.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
        offer = nil
    }

    private static let panelSize = NSSize(width: 460, height: 200)

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false,
        )
        panel.delegate = self
        panel.title = "Sevoflurane"
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }

    /// The close button is "Not Now".
    func windowShouldClose(_: NSWindow) -> Bool {
        offer?.notNow()
        return false
    }
}

private struct SettingOfferView: View {
    let offer: SettingOffer

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            Text(offer.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            Text(offer.footnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            choices
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: offer.symbol)
                .font(.system(size: 28))
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(offer.title)
                    .font(.system(size: 15, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(offer.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var choices: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Don't Ask for This Game") { offer.stopAsking() }
            Spacer()
            Button("Not Now") { offer.notNow() }
                .keyboardShortcut(.cancelAction)
            Button(offer.acceptTitle) { offer.accept() }
                .keyboardShortcut(.defaultAction)
        }
    }
}
