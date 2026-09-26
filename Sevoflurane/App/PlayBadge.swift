import Propofol
import SwiftUI

/// The launch affordance every row of the games column shares: a filled
/// accent disc big enough to read as the row's button, in place of the small
/// tinted glyph a pointer had to hunt for. It appears on hover, and a spinner
/// replaces it for the length of a launch.
struct PlayBadge: View {
    let isBusy: Bool
    let isHovered: Bool

    var body: some View {
        if isBusy {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.8)
                .frame(width: 26, height: 26)
        } else {
            Image(systemName: "play.fill")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Theme.onAccent)
                .frame(width: 26, height: 26)
                .background(Color.accentColor, in: Circle())
                .opacity(isHovered ? 1 : 0)
                .scaleEffect(isHovered ? 1 : 0.7)
        }
    }
}
