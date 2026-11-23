import Foundation
import Testing
@testable import Sevoflurane

/// The rules of the Settings kit that a test can hold: where an anchor leads,
/// what a section says about when a change applies, and how a row's words are
/// written.
@MainActor
struct SettingsKitTests {
    @Test
    func `every anchor resolves to the pane its name starts with`() {
        for anchor in SettingsAnchor.allCases {
            let pane = anchor.category
            #expect(anchor.rawValue.hasPrefix("\(pane.rawValue)."), "\(anchor.rawValue) resolves to \(pane.rawValue)")
            // A jump reads its target aloud as pane › row.
            #expect(anchor.destination.hasPrefix("\(pane.title) › "), "\(anchor.rawValue)")
            #expect(anchor.destination != anchor.rawValue)
        }
    }

    @Test
    func `a change applies in exactly two sentences`() {
        let sentences = [SettingReach.nextLaunch, .clientRestart, .env, .registry, .renderer(.dxmt), .renderer(nil)]
            .map(\.note.key)
        #expect(Set(sentences) == ["Applies the next time a game starts.", "Applies after Steam restarts."])
    }

    @Test
    func `a catalog row's words follow the rules for a row`() {
        for setting in SettingCatalog.all {
            let copy = setting.copy
            #expect(!copy.title.hasSuffix("."), "\(setting.id): a title ends with no period")
            #expect(copy.caption.isEmpty || copy.caption.hasSuffix("."), "\(setting.id): a caption ends with a period")
            #expect(Self.sentences(in: copy.caption) <= 2, "\(setting.id): \(copy.caption)")
            for place in ["Settings ›", " above", " below", "(i)"] {
                #expect(!copy.caption.contains(place), "\(setting.id): the caption names a place: \(place)")
            }
            for text in Self.words(of: copy) {
                #expect(!text.contains("'"), "\(setting.id): a straight apostrophe in “\(text)”")
                #expect(!text.contains("\""), "\(setting.id): a straight quote in “\(text)”")
                #expect(!text.contains(" & "), "\(setting.id): “&” in “\(text)”")
            }
        }
    }

    @Test
    func `every word the setting catalog shows has Simplified Chinese`() throws {
        let catalog = try Self.stringCatalog()
        // A help entry's name can be a product's own, which has no translation.
        var words = SettingCatalog.all.flatMap { setting in
            [setting.copy.title, setting.copy.caption, setting.copy.help?.summary ?? ""]
                + (setting.copy.help?.entries.map(\.text) ?? [])
        }
        words += SettingGroup.allCases.map(\.title)
        words += [SettingReach.nextLaunch, .clientRestart].map(\.note.key)
        for text in words where !text.isEmpty {
            #expect(catalog[text]?.isEmpty == false, "no Simplified Chinese for “\(text)”")
        }
    }

    @Test
    func `every string in the catalog has Simplified Chinese`() throws {
        for (key, translation) in try Self.stringCatalog() {
            #expect(!translation.isEmpty || key.trimmingCharacters(in: .whitespaces).isEmpty, "“\(key)”")
        }
    }

    // MARK: - Scratch

    /// A setting's title, caption and every string of its help.
    private static func words(of copy: SettingCopy) -> [String] {
        var words = [copy.title, copy.caption]
        if let help = copy.help {
            words += [help.title, help.summary, help.footnote ?? ""]
            words += help.entries.flatMap { [$0.name, $0.text] }
        }
        return words
    }

    private static func sentences(in text: String) -> Int {
        text.components(separatedBy: ". ").count
    }

    /// The source catalog's keys with their Simplified Chinese; a key with
    /// none maps to an empty string.
    private static func stringCatalog() throws -> [String: String] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sevoflurane/Localizable.xcstrings")
        let catalog = try JSONDecoder().decode(Catalog.self, from: Data(contentsOf: url))
        return catalog.strings.mapValues { $0.localizations?["zh-Hans"]?.stringUnit?.value ?? "" }
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable {
                    let value: String
                }

                let stringUnit: Unit?
            }

            let localizations: [String: Localization]?
        }

        let strings: [String: Entry]
    }
}
