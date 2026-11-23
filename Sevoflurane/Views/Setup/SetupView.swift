import Propofol
import SwiftUI

/// The first-run assistant: the screen its store is on. Each screen draws
/// its own content and its own buttons.
struct SetupView: View {
    let store: SetupStore

    var body: some View {
        Group {
            switch store.screen {
            case .welcome: SetupWelcomeStep(store: store)
            case .whichSteam: SetupWhichSteamStep(store: store)
            case .engine: SetupEngineStep(store: store)
            case .progress: SetupProgressStep(store: store)
            case .done: SetupDoneStep(store: store)
            }
        }
        .frame(width: SetupMetrics.windowSize.width)
        .frame(maxHeight: .infinity)
        // The screen fills the titlebar too and its top inset clears the
        // traffic lights; inside the safe area the footer would be cut off.
        .ignoresSafeArea()
        .task { await store.prepare() }
        .overlay(alignment: .topTrailing) {
            if store.provisioner.isDryRun { SetupDemoBadge() }
        }
    }
}

/// Marks a simulated run (`SetupDryRun.swift`).
private struct SetupDemoBadge: View {
    var body: some View {
        Text(verbatim: "DEMO")
            .font(.caption2.bold())
            .foregroundStyle(.orange)
            .padding(.horizontal, Theme.Space.sm)
            .padding(.vertical, 3)
            .background(.orange.opacity(0.15), in: Capsule())
            .padding(Theme.Space.md)
            .help(Text(verbatim: "Simulated setup. Nothing on this Mac changes."))
    }
}
