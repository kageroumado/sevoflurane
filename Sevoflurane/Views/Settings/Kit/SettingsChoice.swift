import SwiftUI

/// One of several exclusive choices: the whole row chooses it, and the mark
/// in the accessory slot says which one is chosen.
struct SettingsChoice: View {
    let title: LocalizedStringResource
    var caption = ""
    /// A word beside the mark, where one choice is the one to take.
    var value = ""
    let isSelected: Bool
    let select: () -> Void

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            if !value.isEmpty {
                SettingsValueText(text: value)
            }
        } accessory: {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                .accessibilityHidden(true)
        }
        .contentShape(.rect)
        .onTapGesture(perform: select)
        .focusable()
        .onKeyPress(.space) {
            select()
            return .handled
        }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, select)
    }
}
