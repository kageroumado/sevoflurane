import Propofol
import SwiftUI

/// The (i) at a row's trailing edge, and the popover it opens.
struct SettingHelpButton: View {
    let help: SettingHelp
    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: "info.circle")
        }
        .buttonStyle(.borderless)
        .help(help.title)
        .accessibilityLabel("About \(help.title)")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            SettingHelpPopover(help: help)
        }
    }
}

struct SettingHelpPopover: View {
    let help: SettingHelp

    private static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            Text(help.title)
                .font(.headline)
            Text(help.summary)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(help.entries, id: \.name) { entry in
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name).font(.callout.weight(.medium))
                    Text(entry.text)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let footnote = help.footnote {
                Text(footnote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = help.link {
                Link("\(link.title) \(Image(systemName: "arrow.up.right"))", destination: link.url)
                    .font(.callout)
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: Self.width)
    }
}

/// Where every Settings row ends: the control's trailing edge on one line,
/// then one slot for the (i) or the row's own small button.
enum SettingsRowMetrics {
    /// The accessory slot's width, kept by a row with nothing in it.
    static let accessoryWidth: CGFloat = 20
    /// Between the control and the slot.
    static let accessorySpacing = Theme.Space.sm
    /// How far inside its own trailing edge a pop-up button draws its chevron.
    static let popUpInset: CGFloat = 3.5
}

extension View {
    /// Moves a row's pop-up button out by its own inset, so its chevron ends
    /// on the line the switches and buttons end on.
    func endsOnControlLine() -> some View {
        padding(.trailing, -SettingsRowMetrics.popUpInset)
    }
}

/// A row as every pane lays one out: the control, the accessory slot, and at
/// most one short line under both.
struct SettingsRow<Control: View, Accessory: View>: View {
    var caption = ""
    /// Orange for a caption that reports a failure.
    var isWarning = false
    /// How far the caption starts past the row's leading edge, for a title
    /// that follows a mark.
    var captionInset: CGFloat = 0
    @ViewBuilder var control: Control
    @ViewBuilder var accessory: Accessory

    var body: some View {
        // The caption sits under the whole row: inside a picker's label a
        // long value squeezes it.
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack(spacing: SettingsRowMetrics.accessorySpacing) {
                control
                // The slot stays when empty, so every control ends on one line.
                ZStack { accessory }
                    .buttonStyle(.borderless)
                    .frame(width: SettingsRowMetrics.accessoryWidth)
            }
            if !caption.isEmpty {
                Text(caption)
                    .font(.callout)
                    .foregroundStyle(isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, captionInset)
            }
        }
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(
        caption: String = "", isWarning: Bool = false, captionInset: CGFloat = 0,
        @ViewBuilder control: () -> Control,
    ) {
        self.init(caption: caption, isWarning: isWarning, captionInset: captionInset, control: control) {}
    }
}

/// A row whose accessory is its (i), where it has one.
struct HelpedRow<Control: View>: View {
    var caption = ""
    var isWarning = false
    let help: SettingHelp?
    @ViewBuilder var control: Control

    var body: some View {
        SettingsRow(caption: caption, isWarning: isWarning) {
            control
        } accessory: {
            if let help { SettingHelpButton(help: help) }
        }
    }
}

/// A switch with its title, one line on what it changes, and its (i).
struct ToggleRow: View {
    let title: LocalizedStringResource
    var caption = ""
    var help: SettingHelp?
    @Binding var isOn: Bool

    var body: some View {
        HelpedRow(caption: caption, help: help) {
            // Inside the row's stack the switch loses the form's title for VoiceOver.
            Toggle(isOn: $isOn) { Text(title) }
                .toggleStyle(.switch)
                .accessibilityLabel(Text(title))
        }
    }
}

/// A row that acts: its title, its buttons, and one line on when to press them.
struct ActionRow<Actions: View>: View {
    let title: LocalizedStringResource
    var caption = ""
    var isWarning = false
    var help: SettingHelp?
    @ViewBuilder var actions: Actions

    var body: some View {
        HelpedRow(caption: caption, isWarning: isWarning, help: help) {
            LabeledContent {
                actions
            } label: {
                Text(title)
            }
        }
    }
}
