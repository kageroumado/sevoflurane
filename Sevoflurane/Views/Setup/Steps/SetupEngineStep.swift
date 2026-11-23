import Propofol
import SwiftUI

/// Asked where a new Steam could run on either engine: a Mac with a
/// CrossOver that works. Dormison is the one to take: resizable windows,
/// upscaling, a game's own Dock icon, frame-rate limits and Mac versions of
/// games exist only on it.
struct SetupEngineStep: View {
    let store: SetupStore

    var body: some View {
        SetupScreenLayout {
            SetupPage(
                title: "Engine",
                subtitle: "The part that runs Windows games on this Mac.",
            ) {
                SetupList {
                    SettingsChoice(
                        title: "Dormison",
                        caption: String(localized: "Sevoflurane’s own engine. Every feature, free."),
                        value: String(localized: "Recommended"),
                        isSelected: store.engineChoice == .builtIn,
                    ) {
                        store.engineChoice = .builtIn
                    }
                    if let crossover = store.provisioner.detection?.usableCrossOver {
                        SettingsChoice(
                            title: "\(crossover.label)",
                            caption: crossover.licensed
                                ? String(localized: "Uses your CrossOver license. Fewer features.")
                                : String(localized: "Uses your CrossOver trial. Fewer features."),
                            isSelected: store.engineChoice == .crossover,
                        ) {
                            store.engineChoice = .crossover
                        }
                    }
                }
                SetupFootnote(
                    text: "Only with Dormison: resizable game windows, upscaling, each game as its own app in the Dock, frame-rate limits, and Mac versions of games.",
                )
                SetupFootnote(text: "You can switch later in Settings.")
            }
        } secondary: {
            Button("Back") { store.goBack() }
        } primary: {
            Button("Continue") { store.answerQuestion() }
        }
    }
}
