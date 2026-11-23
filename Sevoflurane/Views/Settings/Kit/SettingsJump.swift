import Propofol
import SwiftUI

/// A row that goes to another setting: the whole row is the button, with a
/// chevron in the accessory slot.
struct SettingsJump: View {
    let title: LocalizedStringResource
    var caption = ""
    let target: SettingsAnchor
    @Environment(SettingsNavigation.self) private var navigation: SettingsNavigation?

    var body: some View {
        Button {
            navigation?.reveal(target)
        } label: {
            SettingsRow(title: title, caption: caption) {} accessory: {
                Image(systemName: "chevron.right")
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel(Text(title))
        .accessibilityValue(caption)
        .accessibilityHint("Opens \(target.destination)")
    }
}

extension SettingsAnchor {
    /// The pane the row is in.
    var category: SettingsCategory {
        Self.places[self]?.category ?? .general
    }

    /// The row as a path a person would follow: "Engine › Game dependencies".
    var destination: String {
        guard let place = Self.places[self] else { return rawValue }
        return "\(place.category.title) › \(place.title)"
    }

    private static let places: [SettingsAnchor: (category: SettingsCategory, title: String)] =
        Dictionary(
            SettingsCategory.allCases.flatMap { category in
                category.searchableItems.map { ($0.id, (category, $0.title)) }
            },
            uniquingKeysWith: { first, _ in first },
        )
}

/// Flashes a row a search or a jump sent the user to.
private struct SettingsHighlight: ViewModifier {
    let anchor: SettingsAnchor?
    let highlighted: SettingsAnchor?

    func body(content: Content) -> some View {
        // Spreads past the row so lit and unlit rows stay aligned.
        content
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.control, style: .continuous)
                    .fill(isLit ? Color.accentColor.opacity(0.2) : .clear)
                    .padding(.horizontal, -Theme.Space.sm)
                    .padding(.vertical, -Theme.Space.xs)
                    .animation(.easeInOut(duration: 0.3), value: highlighted),
            )
    }

    private var isLit: Bool {
        guard let anchor else { return false }
        return highlighted == anchor
    }
}

extension View {
    /// Marks this row as the one search flashes for `anchor`, and the one the
    /// form scrolls to.
    ///
    /// Never give two rows of one `ForEach` the same target: an identity
    /// shared between them draws one row's content in both. Rows that share
    /// an anchor pass `isScrollTarget` for one of them.
    @ViewBuilder
    func highlightable(
        _ anchor: SettingsAnchor?, highlighted: SettingsAnchor?, isScrollTarget: Bool = true,
    ) -> some View {
        if let anchor, isScrollTarget {
            modifier(SettingsHighlight(anchor: anchor, highlighted: highlighted)).id(anchor)
        } else {
            modifier(SettingsHighlight(anchor: anchor, highlighted: highlighted))
        }
    }

    /// Marks every row of a section as lit for `anchor`. The section's header
    /// is what the form scrolls to (``SettingsSection/anchor``).
    func highlightableSection(_ anchor: SettingsAnchor, highlighted: SettingsAnchor?) -> some View {
        modifier(SettingsHighlight(anchor: anchor, highlighted: highlighted))
    }
}
