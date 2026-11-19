import AppKit
import Propofol
import SwiftUI

/// The three steps a companion app's wallpapers take to a Mac, shown in a
/// floating panel over Steam while the Workshop opens behind it.
@MainActor
final class CompanionGuide: NSObject, NSWindowDelegate {
    static let shared = CompanionGuide()

    private let panel = DialogPanel(size: NSSize(width: 460, height: 300), title: "Sevoflurane")

    func show(_ companion: GameCompanion) {
        let view = CompanionGuideView(
            companion: companion,
            partnerInstalled: CompanionHandoff.isInstalled(companion),
            onOpenPartner: { [weak self] in
                CompanionHandoff.open(appID: companion.appID)
                self?.close()
            },
            onDone: { [weak self] in self?.close() },
        )
        panel.delegate = self
        panel.show(view)
    }

    private func close() {
        panel.dismiss()
    }

    func windowShouldClose(_: NSWindow) -> Bool {
        close()
        return false
    }
}

private struct CompanionGuideView: View {
    let companion: GameCompanion
    let partnerInstalled: Bool
    let onOpenPartner: () -> Void
    let onDone: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.lg) {
            Text("\(companion.name) wallpapers play through \(companion.partner)")
                .font(.system(size: 15, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                step(
                    1, "square.and.arrow.down", String(localized: "Subscribe"),
                    String(localized: "The Workshop is open in Steam: pick wallpapers there, and Steam downloads them."),
                )
                step(
                    2, "film.stack", String(localized: "\(companion.partner) makes videos"),
                    String(localized: "\(companion.partner) finds the downloads and turns each one into a looping video wallpaper."),
                )
                step(
                    3, "desktopcomputer", String(localized: "Choose in System Settings"),
                    String(localized: "Pick them under Wallpaper, like any video."),
                )
            }
            HStack(spacing: Theme.Space.md) {
                if !partnerInstalled {
                    Text("\(companion.partner) is free, from the maker of Sevoflurane.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button(String(localized: "Done"), action: onDone)
                Button(
                    partnerInstalled
                        ? String(localized: "Open \(companion.partner)") : String(localized: "Get \(companion.partner)"),
                    action: onOpenPartner,
                )
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 460)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func step(_ number: Int, _ symbol: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol)
                .font(.system(size: 22))
                .foregroundStyle(.tint)
                .frame(width: 30)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(number). \(title)")
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
