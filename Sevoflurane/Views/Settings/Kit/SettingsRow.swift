import SwiftUI

/// What a row has to report about itself, beyond its value.
enum SettingsRowState: Equatable {
    case normal
    /// Works, with something to know.
    case warning(String)
    /// Did not work.
    case failure(String)

    /// A failure when there is a message, and normal otherwise.
    static func failure(ifPresent message: String?) -> SettingsRowState {
        message.map(SettingsRowState.failure) ?? .normal
    }

    static func warning(ifPresent message: String?) -> SettingsRowState {
        message.map(SettingsRowState.warning) ?? .normal
    }

    /// The state's reason as a sentence. One passed up from an error starts
    /// in lowercase and ends bare.
    var message: String? {
        switch self {
        case .normal: nil
        case let .warning(message), let .failure(message): message.asSentence
        }
    }

    var status: SettingsStatus.Kind? {
        switch self {
        case .normal: nil
        case .warning: .warning
        case .failure: .failure
        }
    }
}

private extension String {
    /// Starts with a capital where its first word is a plain word, and ends
    /// with a full stop.
    var asSentence: String {
        let text = trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = text.last else { return text }
        let firstWord = text.prefix { !$0.isWhitespace }
        let head = firstWord.allSatisfy(\.isLetter) ? text.prefix(1).uppercased() + text.dropFirst() : text
        return ".!?…。！？".contains(last) ? head : head + "."
    }
}

/// What sits before a row's title, in one column for every row that has one.
enum SettingsRowMark: Equatable {
    /// A dot of a chart's color; `nil` keeps the column and draws nothing.
    case dot(Color?)
    case symbol(String)
}

/// A short remark that takes the caption's place, with the one thing to do
/// about it: a value the fix list set, with its undo.
struct SettingsRowNote {
    let text: LocalizedStringResource
    let actionTitle: LocalizedStringResource
    /// Why the remark is there, as the tooltip and VoiceOver's hint.
    let reason: String
    let action: () -> Void
}

/// The one row layout of the Settings window.
///
/// A control line of fixed height holds the title, the control with its
/// trailing edge on one line, and the accessory slot after it; everything on
/// it is centered on that line. At most one line of text sits under the whole
/// row, at one gap from the control line.
struct SettingsRow<Control: View, Accessory: View>: View {
    let title: LocalizedStringResource?
    var caption = ""
    var state = SettingsRowState.normal
    var help: SettingHelp?
    var mark: SettingsRowMark?
    var note: SettingsRowNote?
    /// Shows a spinner before the control.
    var isWorking = false
    /// The control reads the title to VoiceOver itself, so the title's own
    /// text is hidden from it.
    var controlCarriesTitle = false
    /// The title is code: a library's name, a variable.
    var titleIsCode = false
    @ViewBuilder var control: Control
    @ViewBuilder var accessory: Accessory

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.captionGap) {
            HStack(spacing: SettingsMetrics.accessoryGap) {
                if let mark { SettingsRowMarkView(mark: mark) }
                if let title {
                    Text(title)
                        .font(titleIsCode ? SettingsType.code : SettingsType.title)
                        .lineLimit(1)
                        .layoutPriority(1)
                        .accessibilityHidden(controlCarriesTitle)
                    Spacer(minLength: SettingsMetrics.titleGap)
                }
                HStack(spacing: SettingsMetrics.controlGap) {
                    if isWorking { ProgressView().controlSize(.small) }
                    control
                }
                SettingsAccessorySlot {
                    if Accessory.self != EmptyView.self {
                        accessory
                    } else if let status = state.status {
                        SettingsStateMark(kind: status, help: help)
                    } else if let help {
                        SettingsHelpButton(help: help)
                    }
                }
            }
            .frame(height: SettingsMetrics.controlLine)
            if let note {
                SettingsRowNoteView(note: note)
                    .padding(.leading, captionInset)
            } else if !line.isEmpty {
                SettingsCaption(text: line, isState: state != .normal, leads: leadingStatus)
                    .padding(.leading, captionInset)
            }
        }
    }

    /// The state's sentence while there is one, the caption otherwise.
    private var line: String {
        state.message ?? caption
    }

    /// A row whose slot holds its own button draws the state's mark at the
    /// head of its sentence.
    private var leadingStatus: SettingsStatus.Kind? {
        Accessory.self == EmptyView.self ? nil : state.status
    }

    private var captionInset: CGFloat {
        mark == nil ? 0 : SettingsMetrics.markWidth + SettingsMetrics.accessoryGap
    }
}

extension SettingsRow where Accessory == EmptyView {
    init(
        title: LocalizedStringResource?, caption: String = "", state: SettingsRowState = .normal,
        help: SettingHelp? = nil, mark: SettingsRowMark? = nil, note: SettingsRowNote? = nil,
        isWorking: Bool = false, controlCarriesTitle: Bool = false, titleIsCode: Bool = false,
        @ViewBuilder control: () -> Control,
    ) {
        self.init(
            title: title, caption: caption, state: state, help: help, mark: mark, note: note,
            isWorking: isWorking, controlCarriesTitle: controlCarriesTitle, titleIsCode: titleIsCode,
            control: control,
        ) {}
    }
}

/// The slot after every control. It keeps its width when empty, so every
/// control ends on one line, and gives every glyph in it one tint.
struct SettingsAccessorySlot<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        ZStack { content }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .frame(width: SettingsMetrics.accessoryWidth, height: SettingsMetrics.controlLine)
    }
}

/// The one line under a row, in the secondary color; a state's sentence is in
/// the label color.
struct SettingsCaption: View {
    let text: String
    var isState = false
    var leads: SettingsStatus.Kind?

    var body: some View {
        if let leads {
            SettingsStatus(leads, text)
        } else {
            Text(text)
                .font(SettingsType.caption)
                .foregroundStyle(isState ? HierarchicalShapeStyle.primary : .secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct SettingsRowMarkView: View {
    let mark: SettingsRowMark

    var body: some View {
        Group {
            switch mark {
            case let .dot(color):
                Circle()
                    .fill(color ?? .clear)
                    .frame(width: SettingsMetrics.dot, height: SettingsMetrics.dot)
            case let .symbol(name):
                Image(systemName: name)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: SettingsMetrics.markWidth)
        .accessibilityHidden(true)
    }
}

private struct SettingsRowNoteView: View {
    let note: SettingsRowNote

    var body: some View {
        HStack(spacing: SettingsMetrics.captionGap) {
            Text(note.text)
                .foregroundStyle(.secondary)
            Text(verbatim: "·")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Button(action: note.action) { Text(note.actionTitle) }
                .buttonStyle(.link)
                .accessibilityHint(note.reason)
        }
        .font(SettingsType.caption)
        .help(note.reason)
    }
}
