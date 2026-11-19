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

/// A row with a control, an optional (i), and at most one short line under
/// the whole row.
struct HelpedRow<Control: View>: View {
    var caption = ""
    var isWarning = false
    let help: SettingHelp?
    @ViewBuilder var control: Control

    var body: some View {
        CaptionedRow(caption: caption, isWarning: isWarning) {
            HStack(spacing: Theme.Space.sm) {
                control
                if let help {
                    SettingHelpButton(help: help)
                } else {
                    // The column stays, so a control lines up with its neighbors'.
                    Image(systemName: "info.circle").hidden().accessibilityHidden(true)
                }
            }
        }
    }
}
