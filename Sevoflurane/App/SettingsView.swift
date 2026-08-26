import ServiceManagement
import SwiftUI

/// Settings: General (login item), Repair (the idempotent provisioner,
/// re-run on demand), About. The wizard covers first run; this is
/// everything after it.
struct SettingsView: View {
    let provisioner: Provisioner
    @State private var openAtLogin = false
    @State private var graphics = BottleGraphics.Selection(renderer: .auto, msync: true)
    @State private var graphicsLoaded = false

    var body: some View {
        TabView {
            Tab("General", systemImage: "gear") { general }
            Tab("Graphics", systemImage: "cpu") { graphicsPane }
            Tab("Repair", systemImage: "wrench.and.screwdriver") { repair }
            Tab("About", systemImage: "info.circle") { about }
        }
        .frame(width: 440)
        .onAppear {
            openAtLogin = provisioner.openAtLogin
            graphics = Self.currentGraphics()
            graphicsLoaded = true
        }
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

    /// The renderers the active engine can actually switch between.
    /// D3DMetal under the managed engine waits on clean-machine validation
    /// (release-plan R2.4), so it is only offered under CrossOver.
    private var availableRenderers: [Renderer] {
        Engine.active == .crossover
            ? Renderer.allCases
            : [.auto, .dxmt, .dxvk, .wined3d]
    }

    private var graphicsPane: some View {
        Form {
            Section {
                Picker("Game renderer", selection: $graphics.renderer) {
                    ForEach(availableRenderers, id: \.self) { renderer in
                        Text(renderer.label).tag(renderer)
                    }
                }
                Text(graphics.renderer.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Toggle(isOn: $graphics.msync) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enhanced synchronization (msync)")
                        Text("Faster in most games. Turn off if a game deadlocks at launch.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
            } footer: {
                Text("Steam's own interface never touches Direct3D — changes "
                    + "take effect the next time a game starts.")
            }
        }
        .formStyle(.grouped)
        .onChange(of: graphics) { _, selection in
            guard graphicsLoaded else { return }
            applyGraphics(selection)
        }
    }

    private static func currentGraphics() -> BottleGraphics.Selection {
        Engine.active == .crossover
            ? BottleGraphics.selection(forBottle: SteamBottle.root)
            : BottleGraphics.managedSelection()
    }

    private func applyGraphics(_ selection: BottleGraphics.Selection) {
        switch Engine.active {
        case .crossover:
            do {
                try BottleGraphics.apply(selection, toBottle: SteamBottle.root)
                EventLog.shared.log(
                    .setup,
                    "graphics: renderer=\(selection.renderer.rawValue) msync=\(selection.msync)",
                )
            } catch {
                EventLog.shared.log(.setup, "graphics change failed: \(error)")
            }
        case .managed:
            BottleGraphics.setManagedSelection(selection)
            EventLog.shared.log(
                .setup,
                "graphics: renderer=\(selection.renderer.rawValue) msync=\(selection.msync)",
            )
        }
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
