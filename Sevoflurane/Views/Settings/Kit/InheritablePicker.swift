import SwiftUI

/// A per-game setting: the menu's first choice is Inherit with the level
/// above's value in it, and the caption stays the setting's own description.
struct InheritablePicker<Options: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var note: SettingsRowNote?
    var isWorking = false
    /// What the level above resolves to, in the words its own menu uses.
    let inherited: String
    /// The game's own value; `nil` inherits.
    @Binding var selection: String?
    /// The choices, each tagged with its stored `String` value.
    @ViewBuilder var options: Options

    private static var inheritTag: String { "" }

    var body: some View {
        SettingsPicker(
            title: title, caption: caption, state: state, help: help, note: note, isWorking: isWorking,
            selection: tag,
        ) {
            Text("Inherit (\(inherited))").tag(Self.inheritTag)
            options
        }
    }

    private var tag: Binding<String> {
        Binding(
            get: { selection ?? Self.inheritTag },
            set: { selection = $0 == Self.inheritTag ? nil : $0 },
        )
    }
}
