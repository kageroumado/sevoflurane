import Propofol
import SwiftUI

// What the popover needs beyond Propofol, which supplies chips, section labels, headers
// and the radius/spacing ladder.

/// The uniform pressed state: content dims, nothing moves.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// A notice card's symbol size and slot, shared by every kageroumado popover's
/// status card.
private enum NoticeCardMetrics {
    static let symbolSize: CGFloat = 26
    static let symbolSlot: CGFloat = 30
}

/// A notice in the popover: what happened, one line on it, and the actions
/// under the words, since buttons beside them leave a one-word column in a
/// 320-point popover.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    var tint: Color?
    /// Turns the symbol while the thing it reports is under way.
    var isSpinning = false
    /// How far a variable symbol is filled, 0 to 1.
    var level: Double?
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    /// Makes the whole card the button, marked by a trailing chevron.
    var onTap: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                card.contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            // VoiceOver reads the notice whole, then offers its actions.
            card.accessibilityElement(children: .contain)
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol, variableValue: level)
                .font(.system(size: NoticeCardMetrics.symbolSize))
                .symbolRenderingMode(.hierarchical)
                // A gauge's arc is one layer, which the default color mode dims
                // whole (full or empty); draw mode fills it.
                .symbolVariableValueMode(.draw)
                .foregroundStyle(tint ?? Color.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSpinning)
                .frame(width: NoticeCardMetrics.symbolSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(.body, design: .rounded).weight(.medium))
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.isHeader)
                if Actions.self != EmptyView.self {
                    HStack(spacing: Theme.Space.sm) {
                        actions
                    }
                    .controlSize(.small)
                    .padding(.top, 2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if onTap != nil {
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
            }
        }
        .padding(Theme.Space.md)
        .glassCard()
    }
}

extension NoticeCard where Actions == EmptyView {
    /// A card that says something and offers nothing to press.
    init(
        symbol: String, tint: Color? = nil, level: Double? = nil,
        title: LocalizedStringResource, detail: LocalizedStringResource,
    ) {
        self.init(symbol: symbol, tint: tint, level: level, title: title, detail: detail) { EmptyView() }
    }

    /// A card that is itself the press, for the one thing it leads to.
    init(
        symbol: String, tint: Color? = nil,
        title: LocalizedStringResource, detail: LocalizedStringResource, onTap: @escaping () -> Void,
    ) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, onTap: onTap) { EmptyView() }
    }
}

extension String {
    /// The supervisor's log-line status phrases, capitalized as a sentence.
    var sentenceCased: String {
        prefix(1).uppercased() + dropFirst()
    }
}
