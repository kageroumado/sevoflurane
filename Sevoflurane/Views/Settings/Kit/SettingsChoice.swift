import SwiftUI

/// One of several exclusive choices: the whole row chooses it, and the mark
/// in the accessory slot says which one is chosen. A control of the row's
/// own (a button that reveals what the choice is) sits before the mark.
struct SettingsChoice<Detail: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    let isSelected: Bool
    let select: () -> Void
    @ViewBuilder var detail: Detail

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            detail
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

extension SettingsChoice where Detail == EmptyView {
    init(title: LocalizedStringResource, caption: String = "", isSelected: Bool, select: @escaping () -> Void) {
        self.init(title: title, caption: caption, isSelected: isSelected, select: select) {}
    }
}
