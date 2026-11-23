import Propofol
import SwiftUI

/// The measurements every screen of the first-run assistant shares.
enum SetupMetrics {
    /// The window at its least: the welcome and the last screen fit it.
    static let windowSize = CGSize(width: 600, height: 560)
    /// The column the titles and the lists sit in.
    static let contentInset: CGFloat = 60
    static let topInset: CGFloat = 52
    static let heroPicture: CGFloat = 112
    static let listRadius: CGFloat = 12
    static let footerPadding: CGFloat = 20
    /// The bar under a screen: its rule, its padding and a button's height.
    static let barHeight: CGFloat = 77
    /// What Apple's page gets inside the window, at most and at least; a
    /// short screen gives it what is left, and the page scrolls in its panel.
    static let applePageHeight: ClosedRange<CGFloat> = 260 ... 430
    /// What a screen with Apple's page up holds besides the page.
    static let applePageSurround: CGFloat = 470
    /// The room left around the window on the screen it is on.
    static let screenMargin: CGFloat = 40
}

/// How tall the assistant's window is: as tall as the screen on show needs,
/// up to what the display has room for; past that the screen scrolls over a
/// footer that stays put.
@MainActor
@Observable
final class SetupLayout {
    /// The height the screen's own content takes, without its bar; zero for
    /// a screen that fits the window at its least.
    var pageHeight: CGFloat = 0
    var hasBar = true
    /// The tallest the window may be: the display's visible height, less a margin.
    var heightLimit: CGFloat = .infinity

    var windowHeight: CGFloat {
        let wanted = pageHeight + (hasBar ? SetupMetrics.barHeight : 0)
        return min(max(SetupMetrics.windowSize.height, wanted.rounded(.up)), heightLimit)
    }

    /// The height Apple's page gets: what the display leaves it.
    var applePageHeight: CGFloat {
        let range = SetupMetrics.applePageHeight
        return min(max(range.lowerBound, heightLimit - SetupMetrics.applePageSurround), range.upperBound)
    }
}

/// One screen: its content over the bar with its buttons. A screen with
/// nothing to press has no bar.
struct SetupScreenLayout<Content: View, Secondary: View, Primary: View>: View {
    var hasButtons = true
    @ViewBuilder var content: Content
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var primary: Primary
    @Environment(SetupLayout.self) private var layout

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if hasButtons {
                bar
            }
        }
        .onChange(of: hasButtons, initial: true) { _, hasButtons in layout.hasBar = hasButtons }
    }

    private var bar: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.md) {
                secondary
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                Spacer(minLength: Theme.Space.md)
                primary
                    .buttonStyle(PrimaryCapsuleButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.extraLarge)
            .padding(SetupMetrics.footerPadding)
        }
    }
}

/// A question or the work: a title and subtitle over the screen's lists, in
/// one leading-aligned column. It tells the window how tall it is, and
/// scrolls where the display is too short for it.
struct SetupPage<Content: View>: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource?
    @ViewBuilder var content: Content
    @Environment(SetupLayout.self) private var layout

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.title2.weight(.semibold))
                if let subtitle {
                    Text(subtitle)
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
                VStack(alignment: .leading, spacing: Theme.Space.md) {
                    content
                }
                .padding(.top, Theme.Space.xl)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.horizontal, SetupMetrics.contentInset)
            .padding(.top, SetupMetrics.topInset)
            .padding(.bottom, Theme.Space.xl)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { layout.pageHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
    }
}

/// A screen with its picture, title and caption centered: the welcome and
/// the finish.
struct SetupHero<Picture: View, Content: View>: View {
    let title: LocalizedStringResource
    let caption: Text
    @ViewBuilder var picture: Picture
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            picture
                .frame(height: SetupMetrics.heroPicture)
            Text(title)
                .font(.title.weight(.semibold))
                .padding(.top, Theme.Space.lg)
            caption
                .font(.title3)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            content
                .padding(.top, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, SetupMetrics.contentInset)
        .padding(.top, SetupMetrics.topInset + Theme.Space.lg)
    }
}

/// The assistant's one row container: Settings kit rows on one rounded fill,
/// a hairline between them.
struct SetupList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(rows.enumerated(), id: \.element.id) { index, row in
                    if index > 0 { Divider() }
                    row.padding(.vertical, Theme.Space.sm)
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: SetupMetrics.listRadius, style: .continuous))
    }
}

/// A row that opens what it names under itself, its chevron in the label
/// color; the open state is the caller's.
struct SetupDisclosureRow: View {
    let title: LocalizedStringResource
    @Binding var isOpen: Bool

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
        } label: {
            SettingsRow(title: title) {} accessory: {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The small print under a list, in the kit's caption type.
struct SetupFootnote: View {
    let text: LocalizedStringResource

    var body: some View {
        Text(text)
            .font(SettingsType.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.lg)
    }
}
