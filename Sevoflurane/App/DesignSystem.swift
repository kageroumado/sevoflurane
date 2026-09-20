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

/// A notice in the popover: what happened, one line on it, and what can be
/// done, under the words. Buttons beside the words leave a column a word wide
/// in a popover 320 points across.
struct NoticeCard<Actions: View>: View {
    let symbol: String
    var tint: Color?
    /// Turns the symbol while the thing it reports is under way.
    var isSpinning = false
    let title: String
    let detail: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Image(systemName: symbol)
                .font(.title3)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(tint ?? Color.secondary)
                .symbolEffect(.rotate, options: .repeat(.continuous), isActive: isSpinning)
                .frame(width: 24)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: Theme.Space.sm) {
                    actions
                }
                .controlSize(.small)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Theme.Space.md)
        .glassCard()
    }
}
