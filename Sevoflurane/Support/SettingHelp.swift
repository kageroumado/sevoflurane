import Foundation

/// What a setting's (i) button says: the long explanation a row has no room
/// for, so the row keeps a title and at most one short line.
nonisolated struct SettingHelp: Equatable, Sendable {
    /// One named choice or term, with what it means.
    struct Entry: Equatable, Sendable {
        let name: String
        let text: String
    }

    let title: String
    let summary: String
    var entries: [Entry] = []
    /// The small print under the entries: when a change applies, what to try.
    var footnote: String?
    /// Where the vendor documents the thing, for the reader who wants it.
    var link: Link?

    struct Link: Equatable, Sendable {
        let title: String
        let url: URL
    }
}
