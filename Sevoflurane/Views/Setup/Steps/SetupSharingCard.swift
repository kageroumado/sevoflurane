import Propofol
import SwiftUI

/// The sharing question, asked while Steam installs: what is sent, when,
/// that nothing identifies the player, how to undo it, and the exact payload.
/// Its two answers are the screen's buttons.
struct SetupSharingCard: View {
    @State private var showsPayload = false

    var body: some View {
        SetupList {
            VStack(alignment: .leading, spacing: Theme.Space.sm) {
                Text("Help other Mac players")
                    .font(SettingsType.heading)
                Text(SharingCopy.offer)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SharingCopy.whatIsSent)
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("You can stop, or delete what you shared, in Settings \u{203A} General.")
                    .font(SettingsType.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SetupDisclosureRow(title: "Exactly what is sent", isOpen: $showsPayload)
            if showsPayload {
                SettingsCodeBlock(text: SharedRunPreview.json)
            }
        }
    }
}

/// The sentences every surface that asks the sharing question says.
enum SharingCopy {
    static let offer: LocalizedStringResource =
        "Share how each game ran, so everyone can see, on each game\u{2019}s page, what plays well on which Mac."
    static let whatIsSent: LocalizedStringResource =
        "After a game closes, Sevoflurane sends its frame rate, resolution, engine and settings, with your Mac\u{2019}s model and chip. Nothing identifies you, your Mac or your Steam account."
}
