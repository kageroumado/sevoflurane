import ServiceManagement
import SwiftUI

/// Settings: General (login item), Repair (the idempotent provisioner,
/// re-run on demand), About. The wizard covers first run; this is
/// everything after it.
struct SettingsView: View {
    let provisioner: Provisioner
    @State private var openAtLogin = false

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") { general }
            Tab("Repair", systemImage: "wrench.and.screwdriver") { repair }
            Tab("About", systemImage: "info.circle") { about }
        }
        .frame(width: 440)
        .onAppear { openAtLogin = provisioner.openAtLogin }
    }

    private var general: some View {
        Form {
            Section {
                Toggle(isOn: $openAtLogin) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open at login")
                        Text("Sevoflurane starts in the menu bar. No windows until you ask.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .onChange(of: openAtLogin) { _, enabled in
                    provisioner.setOpenAtLogin(enabled)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var repair: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    switch provisioner.activity {
                    case let .working(phase):
                        ProgressView().controlSize(.small)
                        Text(phase)
                    case let .failed(reason):
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(reason).font(.callout)
                    case .done:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Steam is ready.")
                    case .idle:
                        Image(systemName: "checkmark.circle")
                            .foregroundStyle(.secondary)
                        Text("Nothing in progress.")
                    }
                    Spacer()
                    Button("Repair") {
                        Task { await provisioner.provisionAndConfigure() }
                    }
                    .disabled(isWorking)
                }
            } footer: {
                Text("Runs the same setup as first launch: anything present is "
                    + "kept, anything missing or broken is reinstalled. Games "
                    + "and saves are untouched.")
            }
        }
        .formStyle(.grouped)
        .task { await provisioner.refreshDetection() }
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }

    private var about: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 72, height: 72)
            Text("Sevoflurane")
                .font(.system(size: 18, weight: .bold))
            Text("Steam for macOS, natively — version \(Self.version)")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack(spacing: 14) {
                Link(
                    "made by kageroumado \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://kagerou.glass")!,
                )
                Link(
                    "GitHub \(Image(systemName: "arrow.up.right"))",
                    destination: URL(string: "https://github.com/kageroumado/sevoflurane")!,
                )
            }
            .font(.system(size: 12))
        }
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}

#Preview {
    SettingsView(provisioner: Provisioner())
}
