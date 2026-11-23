import SwiftUI

/// The (i) in a row's accessory slot, and the popover it opens.
struct SettingsHelpButton: View {
    let help: SettingHelp
    var symbol = "info.circle"
    /// The glyph's own color, for a state's mark; the slot's tint otherwise.
    var tint: Color?
    @State private var isShowing = false

    var body: some View {
        Button { isShowing = true } label: {
            Image(systemName: symbol)
                .foregroundStyle(tint.map(AnyShapeStyle.init) ?? AnyShapeStyle(.secondary))
        }
        .buttonStyle(.borderless)
        .help(help.title)
        .accessibilityLabel("About \(help.title)")
        .popover(isPresented: $isShowing, arrowEdge: .bottom) {
            SettingsHelpPopover(help: help)
        }
    }
}

struct SettingsHelpPopover: View {
    let help: SettingHelp

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.popoverGap) {
            Text(help.title)
                .font(SettingsType.helpTitle)
            Text(help.summary)
                .font(SettingsType.helpBody)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(help.entries, id: \.name) { entry in
                VStack(alignment: .leading, spacing: SettingsMetrics.popoverTermGap) {
                    Text(entry.name).font(SettingsType.helpTerm)
                    Text(entry.text)
                        .font(SettingsType.helpBody)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if let footnote = help.footnote {
                Text(footnote)
                    .font(SettingsType.helpFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let link = help.link {
                Link("\(link.title) \(Image(systemName: "arrow.up.right"))", destination: link.url)
                    .font(SettingsType.helpBody)
            }
        }
        .padding(SettingsMetrics.popoverPadding)
        .frame(width: SettingsMetrics.popoverWidth)
    }
}
