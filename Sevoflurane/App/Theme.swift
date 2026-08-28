import Propofol
import SwiftUI

extension Theme {
    /// Foreground for content sitting *on* the gold accent — the Open Steam button, the play
    /// badge, prominent chips. The accent fill stays light in both appearances, so this is a fixed
    /// warm near-black rather than `.primary`, which would flip to white in dark mode and fail
    /// contrast on gold.
    static let onAccent = Color(.sRGB, red: 0.15, green: 0.11, blue: 0.02, opacity: 1)
}
