import SwiftUI

// MARK: - Repair (gallery tile)

/// The gallery's Repair tile — the same `RepairRow` the Engine pane embeds,
/// wrapped in its own Form so it stands alone.
struct RepairSettings: View {
    let provisioner: Provisioner
    let highlighted: SettingsAnchor?

    var body: some View {
        Form {
            Section {
                RepairRow(provisioner: provisioner, highlighted: highlighted)
            } footer: {
                Text("Repair checks the engine, the bottle, and Steam. Your games and saves stay.")
            }
        }
        .formStyle(.grouped)
    }
}
