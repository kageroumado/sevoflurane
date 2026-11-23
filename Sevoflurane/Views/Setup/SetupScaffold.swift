import Propofol
import SwiftUI

/// The measurements every screen of the first-run assistant shares.
enum SetupMetrics {
    static let windowSize = CGSize(width: 600, height: 560)
    /// The window's height while a screen hosts Apple's sign-in page, which
    /// needs the room; kept under the screen's visible height.
    static let tallWindowHeight: CGFloat = 920
    /// The room Apple's page gets inside the tall window.
    static let applePageHeight: CGFloat = 430
    /// The column the titles and the lists sit in.
    static let contentInset: CGFloat = 60
    static let topInset: CGFloat = 52
    static let heroPicture: CGFloat = 112
    static let listRadius: CGFloat = 12
    static let footerPadding: CGFloat = 20
}

/// One screen: its content over the bar with its buttons. A screen with
/// nothing to press has no bar.
struct SetupScreenLayout<Content: View, Secondary: View, Primary: View>: View {
    var hasButtons = true
    @ViewBuilder var content: Content
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var primary: Primary

    var body: some View {
        VStack(spacing: 0) {
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            if hasButtons {
                bar
            }
        }
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
/// one leading-aligned column that scrolls when a screen outgrows the window.
struct SetupPage<Content: View>: View {
    let title: LocalizedStringResource
    var subtitle: LocalizedStringResource?
    @ViewBuilder var content: Content

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
            .padding(.bottom, Theme.Space.lg)
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
