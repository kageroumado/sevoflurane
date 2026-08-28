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
