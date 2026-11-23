import SwiftUI

/// A pane's form: its sections in grouped cards, scrolled to the row a search
/// or a jump lands on. The scroll is immediate, and the row's own flash is
/// the motion that shows where it landed.
struct SettingsForm<Content: View>: View {
    let highlighted: SettingsAnchor?
    @ViewBuilder var content: Content

    var body: some View {
        ScrollViewReader { proxy in
            Form { content }
                .formStyle(.grouped)
                .onChange(of: highlighted, initial: true) { _, anchor in
                    guard let anchor else { return }
                    proxy.scrollTo(anchor, anchor: .center)
                }
        }
    }
}

/// A card with its header, and the text under it.
///
/// Every card has a header. The header carries an (i) only where no row of
/// the card can, and the footer says once when a change to the card's rows
/// applies.
struct SettingsSection<Content: View>: View {
    let title: LocalizedStringResource
    /// The name over the pane's first section: the selected game.
    var heading: String?
    /// The anchor search and jumps know the whole section by; the form
    /// scrolls to its header.
    var anchor: SettingsAnchor?
    var help: SettingHelp?
    /// A total at the header's trailing edge, on the rows' value line.
    var value: String?
    var isWorking = false
    var footer: LocalizedStringResource?
    var reach: SettingReach?
    @ViewBuilder var content: Content

    var body: some View {
        Section {
            content
        } header: {
            if let anchor {
                SettingsHeader(title: title, heading: heading, help: help, value: value, isWorking: isWorking)
                    .id(anchor)
            } else {
                SettingsHeader(title: title, heading: heading, help: help, value: value, isWorking: isWorking)
            }
        } footer: {
            if footer != nil || reach != nil {
                SettingsFooter(footer, reach: reach)
            }
        }
    }
}

private struct SettingsHeader: View {
    let title: LocalizedStringResource
    let heading: String?
    let help: SettingHelp?
    let value: String?
    let isWorking: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SettingsMetrics.headingGap) {
            if let heading {
                Text(heading).font(SettingsType.heading)
            }
            HStack(spacing: SettingsMetrics.headerGap) {
                Text(title)
                if let help {
                    SettingsHelpButton(help: help)
                }
                if value != nil || isWorking {
                    Spacer()
                    if isWorking { ProgressView().controlSize(.small) }
                    if let value {
                        Text(value)
                            .font(SettingsType.value)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            // A total ends where the rows' values end, before their slot.
            .padding(.trailing, value == nil ? 0 : SettingsMetrics.accessoryWidth + SettingsMetrics.accessoryGap)
        }
    }
}

/// The text under a card: what the card is for, then when a change to its
/// rows applies.
struct SettingsFooter: View {
    let text: LocalizedStringResource?
    let reach: SettingReach?

    init(_ text: LocalizedStringResource? = nil, reach: SettingReach? = nil) {
        self.text = text
        self.reach = reach
    }

    var body: some View {
        switch (text, reach) {
        case let (text?, reach?): Text("\(Text(text)) \(Text(reach.note))")
        case let (text?, nil): Text(text)
        case let (nil, reach?): Text(reach.note)
        case (nil, nil): EmptyView()
        }
    }
}

/// When a changed setting applies, in the two sentences Settings uses.
extension SettingReach {
    var note: LocalizedStringResource {
        switch self {
        case .nextLaunch: "Applies the next time a game starts."
        case .clientRestart: "Applies after Steam restarts."
        }
    }
}
