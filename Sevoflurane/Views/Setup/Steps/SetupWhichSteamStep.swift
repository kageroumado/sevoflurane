import Propofol
import SwiftUI

/// Asked on a Mac with several Steams: which one setup takes over, each told
/// apart by what a player knows about it, or a new one.
struct SetupWhichSteamStep: View {
    let store: SetupStore

    var body: some View {
        SetupScreenLayout {
            SetupPage(
                title: "Which Steam?",
                subtitle: "This Mac has \(store.candidates.count). Pick the one with your games.",
            ) {
                SetupList {
                    ForEach(store.candidates) { candidate in
                        SettingsChoice(
                            title: "\(candidate.bottle.name)",
                            caption: Self.facts(of: candidate, namesEngine: namesEngine),
                            isSelected: store.steamChoice == candidate.id,
                        ) {
                            store.steamChoice = candidate.id
                        } detail: {
                            Button("Reveal in Finder", systemImage: "magnifyingglass") {
                                NSWorkspace.shared.activateFileViewerSelecting([candidate.bottle.url])
                            }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Reveal in Finder")
                        }
                    }
                    SettingsChoice(
                        title: "Start a new one",
                        caption: String(localized: "A fresh Steam with no games installed."),
                        isSelected: store.steamChoice == nil,
                    ) {
                        store.steamChoice = nil
                    }
                }
            }
        } secondary: {
            Button("Back") { store.goBack() }
        } primary: {
            Button("Continue") { store.answerQuestion() }
        }
    }

    /// Whether the Steams live with both engines, so each row says which.
    private var namesEngine: Bool {
        Set(store.candidates.map(\.isManaged)).count > 1
    }

    /// "14 games · last played 20 Nov · 86 GB", each part only where known.
    static func facts(of candidate: SteamCandidate, namesEngine: Bool) -> String {
        let facts = candidate.facts
        var parts: [String] = []
        switch facts.games {
        case 0: parts.append(String(localized: "No games installed"))
        case 1: parts.append(String(localized: "1 game"))
        default: parts.append(String(localized: "\(facts.games) games"))
        }
        if let played = facts.lastPlayed {
            let day = played.formatted(.dateTime.day().month(.abbreviated).year())
            parts.append(String(localized: "last played \(day)"))
        }
        if facts.bytes > 0 {
            parts.append(facts.bytes.formatted(.byteCount(style: .file)))
        }
        if namesEngine {
            parts.append(candidate.isManaged ? String(localized: "in Sevoflurane") : String(localized: "in CrossOver"))
        }
        return parts.joined(separator: " · ")
    }
}
