import SwiftUI

@main
struct SevofluraneApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(host: delegate.host, supervisor: delegate.supervisor)
        } label: {
            Image(nsImage: MenuBarIcon.image(badged: delegate.supervisor.needsAttention))
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(provisioner: delegate.provisioner)
        }
    }
}
