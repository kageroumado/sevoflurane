import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralSettings: View {
    let provisioner: Provisioner
    let highlighted: String?
    @State private var openAtLogin = false

    var body: some View {
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
                .highlightable(id: "general.openAtLogin", highlighted: highlighted)
            }
        }
        .formStyle(.grouped)
        .onAppear { openAtLogin = provisioner.openAtLogin }
    }
}

// MARK: - Graphics

struct GraphicsSettings: View {
    let highlighted: String?
    @State private var graphics = BottleGraphics.Selection(renderer: .auto, msync: true)
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Game renderer", selection: $graphics.renderer) {
                        ForEach(availableRenderers, id: \.self) { renderer in
                            Text(renderer.label).tag(renderer)
                        }
                    }
                    Text(graphics.renderer.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.renderer", highlighted: highlighted)
                Toggle(isOn: $graphics.msync) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enhanced synchronization (msync)")
                        Text("Faster in most games. Turn off if a game deadlocks at launch.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .highlightable(id: "graphics.msync", highlighted: highlighted)
            } footer: {
                Text("Steam's own interface never touches Direct3D — changes "
                    + "take effect the next time a game starts.")
            }
        }
        .formStyle(.grouped)
        .onAppear {
            graphics = Self.current()
            loaded = true
        }
        .onChange(of: graphics) { _, selection in
            guard loaded else { return }
            apply(selection)
        }
    }

    /// The renderers the active engine can actually switch between.
    /// D3DMetal under the managed engine waits on clean-machine validation
    /// (release-plan R2.4), so it is only offered under CrossOver.
    private var availableRenderers: [Renderer] {
        Engine.active == .crossover
            ? Renderer.allCases
            : [.auto, .dxmt, .dxvk, .wined3d]
    }

    private static func current() -> BottleGraphics.Selection {
        Engine.active == .crossover
            ? BottleGraphics.selection(forBottle: SteamBottle.root)
            : BottleGraphics.managedSelection()
    }

    private func apply(_ selection: BottleGraphics.Selection) {
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
}

// MARK: - Repair

struct RepairSettings: View {
    let provisioner: Provisioner
    let highlighted: String?

    var body: some View {
        Form {
            Section {
                HStack(spacing: 10) {
                    activity
                    Spacer()
                    Button("Repair") {
                        Task(name: "Repair the installation") {
                            await provisioner.provisionAndConfigure()
                        }
                    }
                    .disabled(isWorking)
                }
                .highlightable(id: "repair.run", highlighted: highlighted)
            } footer: {
                Text("Runs the same setup as first launch: anything present is "
                    + "kept, anything missing or broken is reinstalled. Games "
                    + "and saves are untouched.")
            }
        }
        .formStyle(.grouped)
        .task { await provisioner.refreshDetection() }
    }

    @ViewBuilder
    private var activity: some View {
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
    }

    private var isWorking: Bool {
        if case .working = provisioner.activity { true } else { false }
    }
}

// MARK: - About

struct AboutSettings: View {
    let highlighted: String?

    var body: some View {
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
        .highlightable(id: "about.version", highlighted: highlighted)
        .padding(.vertical, 28)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
            as? String ?? "dev"
    }
}
