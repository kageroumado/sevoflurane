import Propofol
import SwiftUI

/// A pane with a list beside its form: the games, and the selected one's
/// settings.
struct SettingsSplit<Sidebar: View, Detail: View>: View {
    @ViewBuilder var sidebar: Sidebar
    @ViewBuilder var detail: Detail

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .listStyle(.inset)
                .frame(width: SettingsMetrics.sideList)
            Divider()
            detail
        }
    }
}

/// A list row of a split pane: a name, and one quiet line under it.
struct SettingsListRow: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.popoverTermGap) {
            Text(title).lineLimit(1)
            Text(detail)
                .font(SettingsType.legend)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private enum SettingsHeroMetrics {
    static let icon: CGFloat = 72
    static let spacing: CGFloat = 10
    static let linkSpacing: CGFloat = 14
    static let actionsTop: CGFloat = 6
    static let padding: CGFloat = 28
    static let name = Font.system(size: 18, weight: .semibold)
    static let links = Font.system(size: 12)
}

private enum SettingsSheetMetrics {
    static let padding = Theme.Space.lg
    static let width: CGFloat = 760
    static let height: CGFloat = 820
}

/// A pane that is one centered card: what the app is, its links, and its
/// buttons.
struct SettingsHero<Links: View, Actions: View>: View {
    let name: String
    let detail: String
    /// Takes the detail's place when an action failed.
    var failure: String?
    @ViewBuilder var links: Links
    @ViewBuilder var actions: Actions

    private typealias Metrics = SettingsHeroMetrics

    /// In a scroll view like every other pane: the split view hangs its title
    /// bar and sidebar on the detail's scroll view, and without one the
    /// sidebar's rows sit above the window's top.
    var body: some View {
        ScrollView {
            card.containerRelativeFrame(.vertical, alignment: .center)
        }
    }

    private var card: some View {
        VStack(spacing: Metrics.spacing) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: Metrics.icon, height: Metrics.icon)
                .accessibilityHidden(true)
            Text(verbatim: name)
                .font(Metrics.name)
            Text(verbatim: detail)
                .font(SettingsType.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: Metrics.linkSpacing) { links }
                .font(Metrics.links)
            HStack(spacing: Metrics.spacing) { actions }
                .controlSize(.small)
                .padding(.top, Metrics.actionsTop)
            if let failure {
                SettingsStatus(.failure, failure)
            }
        }
        .padding(.vertical, Metrics.padding)
        .frame(maxWidth: .infinity)
    }
}

/// A small square picture on the control line: an image, or the letters that
/// stand in for one on a color.
struct SettingsThumbnail: View {
    let image: NSImage?
    let letters: String
    let color: Color

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                ZStack {
                    color
                    Text(verbatim: letters)
                        .font(.system(size: SettingsMetrics.thumbnail * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: SettingsMetrics.thumbnail, height: SettingsMetrics.thumbnail)
        .clipShape(.rect(cornerRadius: SettingsMetrics.thumbnailRadius))
        .accessibilityHidden(true)
    }
}

/// A sheet a row opens: its content, and Done under a divider.
struct SettingsSheet<Content: View>: View {
    /// Holds Done back while the content is working.
    let isBusy: Bool
    let done: () -> Void
    @ViewBuilder var content: Content

    private typealias Metrics = SettingsSheetMetrics

    var body: some View {
        VStack(spacing: 0) {
            content
                .padding(Metrics.padding)
            Divider()
            HStack {
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
                    .disabled(isBusy)
            }
            .padding(Metrics.padding)
        }
        .frame(width: Metrics.width, height: Metrics.height)
    }
}
