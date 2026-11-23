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
                subtitle: "This Mac has CrossOver, so Steam can run on either.",
            ) {
                SetupList {
                    SettingsChoice(
                        title: "Dormison",
                        caption: String(localized: "Sevoflurane\u{2019}s own engine. Free."),
                        isSelected: store.engineChoice == .builtIn,
                    ) {
                        store.engineChoice = .builtIn
                    }
                    if let crossover = store.provisioner.detection?.usableCrossOver {
                        SettingsChoice(
                            title: "\(crossover.label)",
                            caption: String(localized: "From CodeWeavers. \(crossover.licenseWord)"),
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
