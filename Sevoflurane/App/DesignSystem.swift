import Propofol
import SwiftUI

// What the popover needs beyond Propofol: the pressed state every control shares, and the
// full-width accent fill of the one hero action. Chips, section labels, headers, and the
// radius/spacing ladder come from the package.

/// The uniform pressed state: content dims, nothing moves.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The primary action: solid accent that saturates on hover. The hover state
/// lives in an inner view — `@State` on the ButtonStyle itself has no view
/// storage behind it.
struct ProminentFillStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        ProminentFill(configuration: configuration)
    }

    private struct ProminentFill: View {
        let configuration: Configuration
        @State private var isHovered = false

        var body: some View {
            configuration.label
                .background(
                    Color.accentColor.opacity(isHovered ? 1 : 0.9),
                    in: Capsule(),
                )
                .opacity(configuration.isPressed ? 0.7 : 1)
                .onHover { hovering in
                    withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
                }
        }
    }
}

/// A notice card's symbol and the slot it sits in: the measure every
/// kageroumado popover's status card uses, so a card reads the same from one
/// menu-bar app to the next.
private enum NoticeCardMetrics {
    static let symbolSize: CGFloat = 26
    static let symbolSlot: CGFloat = 30
}

/// A notice in the popover: what happened, one line on it, and what can be
/// done, under the words. Buttons beside the words leave a column a word wide
/// in a popover 320 points across.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    var tint: Color?
    /// Turns the symbol while the thing it reports is under way.
    var isSpinning = false
    /// How far a variable symbol is filled, 0 to 1.
    var level: Double?
    let title: String
    let detail: String
    /// Makes the whole card the button, marked by a trailing chevron — the
    /// compact form for a card with one way forward.
    var onTap: (() -> Void)?
    @ViewBuilder var actions: Actions

    var body: some View {
        if let onTap {
            Button(action: onTap) {
                card.contentShape(.rect)
            }
            .buttonStyle(.plain)
        } else {
            card
        }
    }

    private var card: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol, variableValue: level)
                .font(.system(size: NoticeCardMetrics.symbolSize))
                .symbolRenderingMode(.hierarchical)
                // A gauge fills by drawing its arc. The default mode, color,
                // dims whole layers, and a gauge's arc is one layer: it shows
                // full or empty and nothing between.
                .symbolVariableValueMode(.draw)
                .foregroundStyle(tint ?? Color.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSpinning)
                .frame(width: NoticeCardMetrics.symbolSlot)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(.body, design: .rounded).weight(.medium))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    init(symbol: String, tint: Color? = nil, level: Double? = nil, title: String, detail: String) {
        self.init(symbol: symbol, tint: tint, level: level, title: title, detail: detail) { EmptyView() }
    }

    /// A card that is itself the press, for the one thing it leads to.
    init(symbol: String, tint: Color? = nil, title: String, detail: String, onTap: @escaping () -> Void) {
        self.init(symbol: symbol, tint: tint, title: title, detail: detail, onTap: onTap) { EmptyView() }
    }
}

extension String {
    /// The supervisor's status phrases are written for a log line; a card
    /// shows them as a sentence.
    var sentenceCased: String {
        prefix(1).uppercased() + dropFirst()
    }
}
