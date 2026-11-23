import Propofol
import SwiftUI

/// Every layout number of the Settings window. A pane composes kit pieces and
/// holds none of its own.
enum SettingsMetrics {
    /// The height of a row's control line. A switch, a pop-up button, a push
    /// button and a line of text are each centered in it, so every row is one
    /// height whatever it holds.
    static let controlLine: CGFloat = 22
    /// The accessory slot's width, kept by a row with nothing in it.
    static let accessoryWidth: CGFloat = 20
    /// Between the control and the slot.
    static let accessoryGap = Theme.Space.sm
    /// Between the pieces of one control: two buttons, a value and a button.
    static let controlGap = Theme.Space.sm
    /// Between the title and the control, at the least.
    static let titleGap = Theme.Space.md
    /// Between the control line and the caption under it.
    static let captionGap = Theme.Space.xs
    /// How far inside its own trailing edge a pop-up button draws its chevron.
    static let popUpInset: CGFloat = 3.5
    /// The column a row's leading mark sits in: a storage dot, a drive.
    static let markWidth: CGFloat = 16
    /// A storage dot's diameter.
    static let dot: CGFloat = 8
    /// Between a section header's title and what follows it on the line.
    static let headerGap: CGFloat = 6
    /// Between a pane's heading and the first section header under it.
    static let headingGap = Theme.Space.sm
    /// A number field's width, which holds six digits.
    static let numberField: CGFloat = 90
    /// A name field's width in an editor's input row, which holds the longest
    /// variable a fix names.
    static let keyField: CGFloat = 170
    /// The widest a value beside a button grows before it truncates.
    static let valueWidth: CGFloat = 260
    /// A small picture on the control line: an avatar.
    static let thumbnail: CGFloat = 22
    static let thumbnailRadius: CGFloat = 4
    /// The help popover's width and padding.
    static let popoverWidth: CGFloat = 380
    static let popoverPadding = Theme.Space.lg
    /// Between a help popover's blocks, and between a term and its text.
    static let popoverGap = Theme.Space.md
    static let popoverTermGap: CGFloat = 1
    /// A capacity bar's height and corner radius.
    static let barHeight: CGFloat = 18
    static let barRadius: CGFloat = 5
    /// A linear progress bar's width on the control line.
    static let progressWidth: CGFloat = 120
    /// The tallest a block of code grows before it scrolls.
    static let codeHeight: CGFloat = 200
    /// The list beside a pane's form: the games.
    static let sideList: CGFloat = 210
    /// The sidebar's least width.
    static let sidebar: CGFloat = 190
    /// The height the title bar's soft edge fades over, above a pane.
    static let titleBar: CGFloat = 42
    /// How long a row stays lit after a search or a jump lands on it.
    static let highlight: Duration = .seconds(1.8)
}

/// Every font of the Settings window.
enum SettingsType {
    /// The name over a pane's sections: the selected game.
    static let heading = Font.title3.weight(.medium)
    /// A row's title, and a control's own text.
    static let title = Font.body
    /// The one line under a row.
    static let caption = Font.callout
    /// A read-only value on the control line.
    static let value = Font.body.monospacedDigit()
    /// A value that is code: a library's name, a variable, a Wine channel.
    static let code = Font.body.monospaced()
    /// A block of code: what a shared run holds.
    static let codeBlock = Font.system(.subheadline, design: .monospaced)
    /// A state in words on the control line.
    static let status = Font.callout
    /// A help popover's title, body and small print.
    static let helpTitle = Font.headline
    static let helpBody = Font.callout
    static let helpTerm = Font.callout.weight(.medium)
    static let helpFootnote = Font.caption
    /// A legend's labels, and a list row's second line.
    static let legend = Font.caption
}
