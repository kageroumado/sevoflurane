import Propofol
import SwiftUI

/// The measurements every step of the first-run assistant shares.
enum SetupMetrics {
    static let windowSize = CGSize(width: 600, height: 660)
    /// The column the glyph, the titles and the lists sit in.
    static let contentInset: CGFloat = 60
    static let topInset: CGFloat = 64
    static let glyphSize: CGFloat = 52
    static let listRadius: CGFloat = 16
    static let rowMinHeight: CGFloat = 46
    static let rowIconWidth: CGFloat = 28
    static let footerPadding: CGFloat = 20
}

/// One step's page: a large glyph, a title with a gray subtitle under it, and
/// the step's lists, all in one leading-aligned column.
struct SetupPage<Content: View>: View {
    let glyph: String
    let title: String
    let subtitle: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Image(systemName: glyph)
                .font(.system(size: SetupMetrics.glyphSize, weight: .regular))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
                .frame(height: SetupMetrics.glyphSize + 8, alignment: .bottomLeading)
                .accessibilityHidden(true)
            Text(title)
                .font(.title2.weight(.semibold))
                .padding(.top, Theme.Space.xl)
            Text(subtitle)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: Theme.Space.md) {
                content
            }
            .padding(.top, Theme.Space.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, SetupMetrics.contentInset)
        .padding(.top, SetupMetrics.topInset)
    }
}

/// A page with its picture, title and caption centered: the welcome and the
/// finish.
struct SetupHero<Picture: View, Content: View>: View {
    let title: String
    let caption: Text
    @ViewBuilder var picture: Picture
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            picture
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
                .padding(.top, Theme.Space.xl + Theme.Space.sm)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.horizontal, SetupMetrics.contentInset)
        .padding(.top, SetupMetrics.topInset)
    }
}

/// A grouped inset list: rows on one rounded fill, a hairline between them
/// that starts where the row titles start.
struct SetupList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content) { rows in
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                            .padding(.leading, SetupMetrics.rowIconWidth + Theme.Space.md)
                    }
                    row
                }
            }
        }
        .padding(.horizontal, Theme.Space.lg)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: SetupMetrics.listRadius, style: .continuous))
    }
}

/// One row of a ``SetupList``: an icon, a title with an optional caption
/// under it, and whatever the row carries at its trailing edge.
struct SetupRow<Accessory: View>: View {
    let icon: String
    let title: String
    var caption: String?
    var captionStyle: AnyShapeStyle = .init(.secondary)
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: Theme.Space.md) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: SetupMetrics.rowIconWidth)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let caption {
                    Text(caption)
                        .font(.callout)
                        .foregroundStyle(captionStyle)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            accessory
        }
        .padding(.vertical, Theme.Space.sm)
        .frame(minHeight: SetupMetrics.rowMinHeight)
    }
}

extension SetupRow where Accessory == EmptyView {
    init(icon: String, title: String, caption: String? = nil) {
        self.init(icon: icon, title: title, caption: caption) { EmptyView() }
    }
}

/// A row that is one of several exclusive choices: the whole row is the
/// button, and the mark at its trailing edge says which one is chosen.
struct SetupChoiceRow: View {
    let icon: String
    let title: String
    var caption: String?
    /// What the choice costs or is, in the value column: "Free", "Trial".
    var value: String?
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            SetupRow(icon: icon, title: title, caption: caption) {
                if let value {
                    Text(value).foregroundStyle(.secondary)
                }
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The small print under a list.
struct SetupFootnote: View {
    let text: String
    var style: AnyShapeStyle = .init(.secondary)

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(style)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Theme.Space.lg)
    }
}

/// The bar under every step: a hairline across the window, the step's lesser
/// actions at the leading edge and its one primary action at the trailing one.
struct SetupFooter<Secondary: View, Primary: View>: View {
    @ViewBuilder var secondary: Secondary
    @ViewBuilder var primary: Primary

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: Theme.Space.md) {
                secondary
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                Spacer(minLength: Theme.Space.md)
                primary
                    .buttonStyle(SetupPrimaryButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.extraLarge)
            .padding(SetupMetrics.footerPadding)
        }
    }
}

/// The one primary action of a step: the accent in a capsule, with the dark
/// label the accent needs. The system's prominent style drops its fill in a
/// window that is not key, which leaves that dark label on a dark button.
struct SetupPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Face(configuration: configuration)
    }

    private struct Face: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.onAccent)
                .padding(.horizontal, Theme.Space.xl)
                .frame(minHeight: 36)
                .background(Color.accentColor.opacity(isHovered ? 1 : 0.92), in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
                .onHover { isHovered = $0 }
        }
    }
}
