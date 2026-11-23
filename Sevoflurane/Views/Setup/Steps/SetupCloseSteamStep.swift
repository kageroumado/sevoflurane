import Propofol
import SwiftUI

/// Asked before the work starts where a Steam of this app is running and
/// has to be closed for setup to move to the one chosen.
struct SetupCloseSteamStep: View {
    let store: SetupStore

    var body: some View {
        SetupScreenLayout {
            SetupPage(
                title: "Steam is running",
                subtitle: "Setup has to close it to go on.",
            ) {
                SetupList {
                    Text("A game or a download that is running in it stops when Steam closes.")
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } secondary: {
            Button("Not Now") { store.goBack() }
        } primary: {
            Button("Close Steam") { store.answerQuestion() }
        }
    }
}
