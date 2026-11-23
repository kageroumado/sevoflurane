import Propofol
import SwiftUI

/// Asked where a new Steam could run on either engine: a Mac with a
/// CrossOver that works, whose owner has something to judge by.
struct SetupEngineStep: View {
    let store: SetupStore

    var body: some View {
        SetupScreenLayout {
            SetupPage(
                title: "How games run",
                subtitle: "CrossOver is on this Mac, so Steam can use it instead.",
            ) {
                SetupList {
                    SettingsChoice(
                        title: "Dormison",
                        caption: String(localized: "Built into Sevoflurane. Free."),
                        isSelected: store.engineChoice == .builtIn,
                    ) {
                        store.engineChoice = .builtIn
                    }
                    if let crossover = store.provisioner.detection?.usableCrossOver {
                        SettingsChoice(
                            title: "\(crossover.label)",
                            caption: crossover.licensed
                                ? String(localized: "Uses your CrossOver license.")
                                : String(localized: "Uses your CrossOver trial."),
                            isSelected: store.engineChoice == .crossover,
                        ) {
                            store.engineChoice = .crossover
                        }
                    }
                }
                SetupFootnote(text: "You can switch later in Settings.")
            }
        } secondary: {
            Button("Back") { store.goBack() }
        } primary: {
            Button("Continue") { store.answerQuestion() }
        }
    }
}
