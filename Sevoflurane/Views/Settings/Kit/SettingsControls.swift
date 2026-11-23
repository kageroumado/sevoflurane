import SwiftUI

/// A switch.
struct SettingsToggle: View {
    let title: LocalizedStringResource
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var note: SettingsRowNote?
    var isWorking = false
    @Binding var isOn: Bool

    var body: some View {
        SettingsRow(
            title: title, caption: caption, state: state, help: help, note: note,
            isWorking: isWorking, controlCarriesTitle: true,
        ) {
            Toggle(isOn: $isOn) { Text(title) }
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

/// A pop-up menu. Its chevron ends on the line the switches and buttons end on.
struct SettingsPicker<Selection: Hashable, Options: View, Accessory: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var note: SettingsRowNote?
    var isWorking = false
    @Binding var selection: Selection
    @ViewBuilder var options: Options
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingsRow(
            title: title, caption: caption, state: state, help: help, note: note,
            isWorking: isWorking, controlCarriesTitle: true,
        ) {
            SettingsPopUp(title: title, selection: $selection) { options }
        } accessory: {
            accessory
        }
    }
}

extension SettingsPicker where Accessory == EmptyView {
    init(
        title: LocalizedStringResource, caption: String = "", state: SettingsRowState = .normal,
        help: SettingHelp? = nil, note: SettingsRowNote? = nil, isWorking: Bool = false,
        selection: Binding<Selection>, @ViewBuilder options: () -> Options,
    ) {
        self.init(
            title: title, caption: caption, state: state, help: help, note: note, isWorking: isWorking,
            selection: selection, options: options,
        ) {}
    }
}

/// The pop-up button itself, for a row that holds one beside other controls.
/// It is as wide as its value, and gives way before the row's title does:
/// in a narrow pane a long value is cut, and the menu still shows it whole.
struct SettingsPopUp<Selection: Hashable, Options: View>: View {
    let title: LocalizedStringResource
    @Binding var selection: Selection
    @ViewBuilder var options: Options

    var body: some View {
        ViewThatFits(in: .horizontal) {
            picker.fixedSize()
            picker
        }
        .padding(.trailing, -SettingsMetrics.popUpInset)
    }

    private var picker: some View {
        Picker(selection: $selection) { options } label: { Text(title) }
            .labelsHidden()
    }
}

/// One or more buttons. The title names the object; each button carries its
/// verb and the object.
struct SettingsAction<Actions: View, Accessory: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var mark: SettingsRowMark?
    var isWorking = false
    @ViewBuilder var actions: Actions
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingsRow(
            title: title, caption: caption, state: state, help: help, mark: mark, isWorking: isWorking,
        ) {
            actions
        } accessory: {
            accessory
        }
    }
}

extension SettingsAction where Accessory == EmptyView {
    init(
        title: LocalizedStringResource, caption: String = "", state: SettingsRowState = .normal,
        help: SettingHelp? = nil, mark: SettingsRowMark? = nil, isWorking: Bool = false,
        @ViewBuilder actions: () -> Actions,
    ) {
        self.init(
            title: title, caption: caption, state: state, help: help, mark: mark, isWorking: isWorking,
            actions: actions,
        ) {}
    }
}

/// A read-only value.
struct SettingsValue<Accessory: View>: View {
    let title: LocalizedStringResource
    let value: String
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var mark: SettingsRowMark?
    var isCode = false
    @ViewBuilder var accessory: Accessory

    var body: some View {
        SettingsRow(title: title, caption: caption, state: state, help: help, mark: mark) {
            SettingsValueText(text: value, isCode: isCode)
        } accessory: {
            accessory
        }
        .accessibilityElement(children: .contain)
    }
}

extension SettingsValue where Accessory == EmptyView {
    init(
        title: LocalizedStringResource, value: String, caption: String = "",
        state: SettingsRowState = .normal, help: SettingHelp? = nil, mark: SettingsRowMark? = nil,
        isCode: Bool = false,
    ) {
        self.init(
            title: title, value: value, caption: caption, state: state, help: help, mark: mark, isCode: isCode,
        ) {}
    }
}

/// A value's own text on the control line: quiet, one line, cut in the middle
/// when it is longer than its room.
struct SettingsValueText: View {
    let text: String
    var isCode = false

    var body: some View {
        Text(verbatim: text)
            .font(isCode ? SettingsType.code : SettingsType.value)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: SettingsMetrics.valueWidth, alignment: .trailing)
            .fixedSize(horizontal: true, vertical: false)
            .help(text)
    }
}

/// A text field, with the buttons that act on what it holds.
struct SettingsField<Actions: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    var help: SettingHelp?
    var prompt = ""
    @Binding var text: String
    var onSubmit: () -> Void = {}
    @ViewBuilder var actions: Actions

    var body: some View {
        SettingsRow(title: title, caption: caption, help: help, controlCarriesTitle: true) {
            TextField(text: $text, prompt: Text(verbatim: prompt)) { Text(title) }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .frame(width: SettingsMetrics.valueWidth)
                .padding(.trailing, Actions.self == EmptyView.self ? SettingsMetrics.fieldInset : 0)
                .onSubmit(onSubmit)
            actions
        }
    }
}

extension SettingsField where Actions == EmptyView {
    init(
        title: LocalizedStringResource, caption: String = "", help: SettingHelp? = nil, prompt: String = "",
        text: Binding<String>, onSubmit: @escaping () -> Void = {},
    ) {
        self.init(title: title, caption: caption, help: help, prompt: prompt, text: text, onSubmit: onSubmit) {}
    }
}

/// A whole number, held inside a range.
struct SettingsNumberField: View {
    let title: LocalizedStringResource
    var caption = ""
    @Binding var value: Int
    let range: ClosedRange<Int>

    var body: some View {
        SettingsRow(title: title, caption: caption, controlCarriesTitle: true) {
            TextField(value: clamped, format: .number.grouping(.never)) { Text(title) }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: SettingsMetrics.numberField)
                .padding(.trailing, SettingsMetrics.fieldInset)
        }
    }

    private var clamped: Binding<Int> {
        Binding(
            get: { value },
            set: { value = min(max($0, range.lowerBound), range.upperBound) },
        )
    }
}

/// Several choices that can all be on at once, as checkboxes on one line.
struct SettingsChecks<Option: Hashable>: View {
    let title: LocalizedStringResource
    var caption = ""
    let options: [(value: Option, label: String)]
    @Binding var selection: Set<Option>

    var body: some View {
        SettingsRow(title: title, caption: caption) {
            ForEach(options, id: \.value) { option in
                Toggle(option.label, isOn: Binding(
                    get: { selection.contains(option.value) },
                    set: { isOn in
                        if isOn { selection.insert(option.value) } else { selection.remove(option.value) }
                    },
                ))
                .toggleStyle(.checkbox)
            }
        }
    }
}

/// Something under way: its stage as the title, a bar while the fraction is
/// known and a spinner until then, and the button that stops it.
struct SettingsProgress: View {
    let title: String
    var fraction: Double?
    var caption = ""
    var stop: (() -> Void)?

    var body: some View {
        SettingsRow(title: "\(title)", caption: caption) {
            if let fraction {
                ProgressView(value: fraction)
                    .frame(width: SettingsMetrics.progressWidth)
            } else {
                ProgressView().controlSize(.small)
            }
            if let stop {
                Button("Stop", action: stop)
            }
        }
    }
}

/// A line that fills a card with nothing else to show: an empty list.
struct SettingsMessage: View {
    let text: LocalizedStringResource

    var body: some View {
        Text(text)
            .font(SettingsType.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.controlLine, alignment: .leading)
    }
}

/// A row that opens what it names under itself: a chevron in the accessory
/// slot, and the content while it is open.
struct SettingsDisclosure<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder var content: Content
    @State private var isOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { isOpen.toggle() }
            } label: {
                SettingsRow(title: title) {} accessory: {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .ignore)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(Text(title))
            .accessibilityValue(isOpen ? Text("Expanded") : Text("Collapsed"))
            if isOpen { content }
        }
    }
}

/// Text that is data, to read and to copy: it scrolls past a few lines.
struct SettingsCodeBlock: View {
    let text: String

    var body: some View {
        ScrollView {
            Text(verbatim: text)
                .font(SettingsType.codeBlock)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: SettingsMetrics.codeHeight)
    }
}

/// A command to paste elsewhere, with its copy button in the accessory slot.
struct SettingsCode: View {
    let title: LocalizedStringResource
    let code: String
    @State private var copied = false

    var body: some View {
        SettingsRow(title: title, caption: code) {} accessory: {
            SettingsAccessoryButton(
                symbol: copied ? "checkmark" : "doc.on.doc",
                label: String(localized: "Copy"),
            ) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(code, forType: .string)
                copied = true
                Task(name: "Clear the copied mark") {
                    try? await Task.sleep(for: .seconds(1.5))
                    copied = false
                }
            }
        }
        .textSelection(.enabled)
    }
}
