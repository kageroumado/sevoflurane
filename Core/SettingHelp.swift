import Foundation

nonisolated enum InterfaceCopy {
    static func localized(_ key: String) -> String {
        Bundle.main.localizedString(forKey: key, value: key, table: "Localizable")
    }
}

/// What a setting's (i) button says: the long explanation a row has no room
/// for, so the row keeps a title and at most one short line.
nonisolated struct SettingHelp: Equatable, Sendable {
    /// One named choice or term, with what it means.
    struct Entry: Equatable, Sendable {
        let name: String
        let text: String

        init(name: String, text: String) {
            self.name = InterfaceCopy.localized(name)
            self.text = InterfaceCopy.localized(text)
        }
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

        init(title: String, url: URL) {
            self.title = InterfaceCopy.localized(title)
            self.url = url
        }
    }

    init(title: String, summary: String, entries: [Entry] = [], footnote: String? = nil, link: Link? = nil) {
        self.title = InterfaceCopy.localized(title)
        self.summary = InterfaceCopy.localized(summary)
        self.entries = entries
        self.footnote = footnote.map(InterfaceCopy.localized)
        self.link = link
    }
}
