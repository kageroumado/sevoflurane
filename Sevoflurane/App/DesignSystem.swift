import SwiftUI

// The popover's design kit — the kagerou house language's atoms (capsule
// chips, circular icon buttons, the accent-on-ink primary fill), shared
// with every other surface the app grows.

/// Foreground for text on a solid accent fill. The yellow stays light in both
/// schemes, so this is a fixed warm near-black rather than `.primary`, which
/// would flip to white in dark mode and fail contrast.
enum Ink {
    static let onAccent = Color(.sRGB, red: 0.15, green: 0.11, blue: 0.02, opacity: 1)
}

/// The uniform pressed state: content dims, nothing moves.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The primary action: solid accent that saturates on hover.
struct ProminentFillStyle: ButtonStyle {
    @State private var isHovered = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Color.accentColor.opacity(isHovered ? 1 : 0.9),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous),
            )
            .opacity(configuration.isPressed ? 0.7 : 1)
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
    }
}

/// A capsule chip. Neutral chips rest on `.quinary` and lift to `.quaternary`
/// on hover; prominent chips are solid accent with ink text.
struct ChipButton: View {
    let title: String
    var systemImage: String?
    var prominent = false
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .font(.system(size: 10, weight: .medium))
                }
                Text(title)
            }
            .font(.system(size: 11, weight: prominent ? .semibold : .medium))
            .foregroundStyle(prominent ? AnyShapeStyle(Ink.onAccent) : AnyShapeStyle(.secondary))
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(fill, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
    }

    private var fill: AnyShapeStyle {
        if prominent {
            return AnyShapeStyle(Color.accentColor.opacity(isHovered ? 1 : 0.9))
        }
        return isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary)
    }
}

/// A 28 pt circular icon-only button for the footer's client controls.
struct RoundIconButton: View {
    let symbol: String
    let label: String
    let help: String
    var shortcut: KeyEquivalent?
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        button
            .buttonStyle(PressableStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .help(help)
            .accessibilityLabel(label)
    }

    @ViewBuilder private var button: some View {
        let core = Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .background(
                    isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                    in: Circle(),
                )
                .contentShape(Circle())
        }
        if let shortcut {
            core.keyboardShortcut(shortcut)
        } else {
            core
        }
    }
}
