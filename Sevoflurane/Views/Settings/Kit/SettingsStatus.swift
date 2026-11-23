import SwiftUI

/// A state in words. The icon carries the color and the text is in the label
/// color, so the words read as well on a light card as on a dark one.
struct SettingsStatus: View {
    enum Kind: Equatable {
        case done
        case warning
        case failure
        case working

        var symbol: String {
            switch self {
            case .done: "checkmark.circle.fill"
            case .warning: "exclamationmark.triangle.fill"
            case .failure: "xmark.octagon.fill"
            case .working: "circle.dotted"
            }
        }

        var color: Color {
            switch self {
            case .done: .green
            case .warning: .orange
            case .failure: .red
            case .working: .secondary
            }
        }
    }

    let kind: Kind
    let text: String

    init(_ kind: Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        Label(text, systemImage: kind.symbol)
            .labelStyle(SettingsStatusStyle(kind: kind))
    }
}

struct SettingsStatusStyle: LabelStyle {
    let kind: SettingsStatus.Kind

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: SettingsMetrics.captionGap) {
            if kind == .working {
                ProgressView().controlSize(.small)
            } else {
                configuration.icon
                    .foregroundStyle(kind.color)
                    .accessibilityHidden(true)
            }
            configuration.title
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(SettingsType.status)
        .accessibilityElement(children: .combine)
    }
}

/// A state that is a row of its own: a failure that belongs to the whole
/// card.
struct SettingsNotice: View {
    let kind: SettingsStatus.Kind
    let text: String

    init(_ kind: SettingsStatus.Kind, _ text: String) {
        self.kind = kind
        self.text = text
    }

    var body: some View {
        SettingsStatus(kind, text)
            .frame(maxWidth: .infinity, minHeight: SettingsMetrics.controlLine, alignment: .leading)
    }
}

/// A row's state in its accessory slot. Where the row has help, the mark
/// opens it.
struct SettingsStateMark: View {
    let kind: SettingsStatus.Kind
    var help: SettingHelp?

    var body: some View {
        if let help {
            SettingsHelpButton(help: help, symbol: kind.symbol, tint: kind.color)
        } else {
            Image(systemName: kind.symbol)
                .foregroundStyle(kind.color)
                .accessibilityHidden(true)
        }
    }
}
