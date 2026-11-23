import Propofol
import SwiftUI

/// The first screen: what this is, what setup involves, and the one button
/// that starts it.
struct SetupWelcomeStep: View {
    let store: SetupStore

    var body: some View {
        SetupScreenLayout {
            SetupHero(
                title: "Sevoflurane",
                caption: Text("Steam for Windows and its games, on your Mac"),
            ) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: SetupMetrics.heroPicture, height: SetupMetrics.heroPicture)
                    .accessibilityHidden(true)
            } content: {
                Text("Free. Setup downloads Steam and what it needs to run on a Mac. You sign in to Steam at the end.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } secondary: {
            EmptyView()
        } primary: {
            Button("Set Up Steam") { store.begin() }
        }
    }
}
