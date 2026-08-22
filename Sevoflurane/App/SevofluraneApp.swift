import SwiftUI

@main
struct SevofluraneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(host: delegate.host, supervisor: delegate.supervisor)
        } label: {
            Image(systemName: "cloud.fill")
        }
        .menuBarExtraStyle(.window)
    }
}
