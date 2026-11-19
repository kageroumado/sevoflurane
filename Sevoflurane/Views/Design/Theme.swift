import Propofol
import SwiftUI

extension Theme {
    /// Foreground for content sitting *on* the gold accent — the Open Steam button, the play
    /// badge, prominent chips. The accent fill stays light in both appearances, so this is a fixed
    /// warm near-black rather than `.primary`, which would flip to white in dark mode and fail
    /// contrast on gold.
    static let onAccent = Color(.sRGB, red: 0.15, green: 0.11, blue: 0.02, opacity: 1)

    /// The Storage pane's capacity bar. One color per segment, shared by the
    /// bar, its legend and the dot on each row.
    enum Storage {
        /// The largest entries, largest first.
        static let ranked: [Color] = [.blue, .orange, .purple, .teal]
        /// The rest of what Sevoflurane keeps, drawn as one segment.
        static let grouped = Color.brown
        /// Everything on the volume that belongs to someone else.
        static let other = Color(nsColor: .systemGray)
    }
}
