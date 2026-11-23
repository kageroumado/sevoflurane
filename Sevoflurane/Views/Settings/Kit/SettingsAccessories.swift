import SwiftUI

/// A row's own small button in its accessory slot: a trash, an undo, a chevron.
struct SettingsAccessoryButton: View {
    let symbol: String
    /// What the button does, as its tooltip and VoiceOver's label.
    let label: String
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
        }
        .buttonStyle(.borderless)
        .disabled(isDisabled)
        .help(label)
        .accessibilityLabel(label)
    }
}

/// A row's further actions, behind (…) in its accessory slot.
struct SettingsAccessoryMenu<Items: View>: View {
    var isDisabled = false
    @ViewBuilder var items: Items

    var body: some View {
        Menu {
            items
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        // A plain button draws the label as given; a borderless one hands it to
        // AppKit, which draws it in the label color whatever its style says.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(isDisabled)
        .help("More actions")
        .accessibilityLabel("More actions")
    }
}

/// A row's page on the web, in its accessory slot.
struct SettingsAccessoryLink: View {
    let label: LocalizedStringResource
    let destination: URL

    var body: some View {
        Link(destination: destination) {
            Image(systemName: "arrow.up.right.square")
                .foregroundStyle(.secondary)
        }
        .help(Text(label))
        .accessibilityLabel(Text(label))
    }
}
