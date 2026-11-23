import Propofol
import SwiftUI

/// A window's one primary action: the accent in a capsule with a dark label.
/// The system's prominent style drops its fill in a window that is not key,
/// which would leave the dark label on a dark button.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
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
                .padding(.horizontal, Metrics.sidePadding)
                .frame(minHeight: Metrics.height)
                .background(Color.accentColor.opacity(isHovered ? 1 : Metrics.restingFill), in: Capsule())
                .opacity(isEnabled ? (configuration.isPressed ? Metrics.pressed : 1) : Metrics.disabled)
                .onHover { isHovered = $0 }
        }
    }

    private enum Metrics {
        static let sidePadding: CGFloat = 20
        static let height: CGFloat = 36
        static let restingFill = 0.92
        static let pressed = 0.7
        static let disabled = 0.4
    }
}
