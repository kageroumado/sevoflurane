import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var showingRendererHelp = false
    @State private var d3dMetalVersion: String?
    @State private var d3dMetalError: String?
    @State private var isAddingD3DMetal = false

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("Game renderer", selection: $graphics.renderer) {
                            ForEach(availableRenderers, id: \.self) { renderer in
                                Text(renderer.label).tag(renderer)
                            }
                        }
                        Button { showingRendererHelp = true } label: {
                            Image(systemName: "info.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("What each renderer is for")
                        .accessibilityLabel("About the renderers")
                        .popover(isPresented: $showingRendererHelp, arrowEdge: .bottom) {
                            RendererHelp(available: availableRenderers)
                        }
                    }
                    Text(graphics.renderer.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.renderer", highlighted: highlighted)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Report the GPU as", selection: $graphics.gpu) {
                        ForEach(GPUIdentity.allCases, id: \.self) { identity in
                            Text(identity.label).tag(identity)
                        }
                    }
                    Text(graphics.gpu.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.gpu", highlighted: highlighted)
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
            if let managedEngine { d3dMetalSection(engine: managedEngine) }
        }
        .formStyle(.grouped)
        .onAppear {
            graphics = Self.current()
            d3dMetalVersion = managedEngine.flatMap {
                D3DMetalInstaller.active(inEngine: $0)?.version
            }
            loaded = true
        }
        .onChange(of: graphics) { _, selection in
            guard loaded else { return }
            apply(selection)
        }
    }

    /// The renderers the active engine can actually switch between.
    /// CrossOver carries D3DMetal itself; a managed engine has it only once
    /// the user has added their own copy of Apple's toolkit.
    private var availableRenderers: [Renderer] {
        if Engine.active == .crossover { return Renderer.allCases }
        var renderers: [Renderer] = [.auto, .dxmt, .dxvk, .wined3d]
        if managedEngine.map({ !D3DMetalInstaller.installed(inEngine: $0).isEmpty }) == true {
            renderers.insert(.d3dmetal, at: 1)
        }
        return renderers
    }

    /// The managed engine's directory, when one is what we are running on.
    private var managedEngine: URL? {
        guard case let .managed(version) = Engine.active else { return nil }
        return Engine.managedRoot.appendingPathComponent(version)
    }

    /// Apple's Game Porting Toolkit is not ours to ship, so a managed engine
    /// gets D3DMetal from the user's own download — the arrangement Whisky
    /// uses. Releases and betas install side by side; the newest is used
    /// unless another is chosen here.
    @ViewBuilder
    private func d3dMetalSection(engine: URL) -> some View {
        let installed = D3DMetalInstaller.installed(inEngine: engine)
        Section {
            if installed.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add D3DMetal").font(.callout.weight(.semibold))
                    Text("Direct3D 12 needs Apple's Game Porting Toolkit, which only "
                        + "Apple may distribute. Download it from developer.apple.com "
                        + "and point Sevoflurane at the disk image.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("D3DMetal version", selection: $d3dMetalVersion) {
                    ForEach(installed, id: \.version) { entry in
                        Text(entry.version).tag(Optional(entry.version))
                    }
                }
                .onChange(of: d3dMetalVersion) { _, chosen in
                    guard let chosen,
                          let entry = installed.first(where: { $0.version == chosen })
                    else { return }
                    try? D3DMetalInstaller.activate(entry, inEngine: engine)
                }
            }
            HStack {
                if let d3dMetalError {
                    Text(d3dMetalError).font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button(installed.isEmpty ? "Choose Toolkit…" : "Add Another Version…") {
                    addD3DMetal(engine: engine)
                }
                .disabled(isAddingD3DMetal)
            }
        } header: {
            Text("Apple's Game Porting Toolkit")
        }
    }

    private func addD3DMetal(engine: URL) {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit disk image you downloaded."
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isAddingD3DMetal = true
        d3dMetalError = nil
        Task(name: "Install D3DMetal") {
            do {
                let entry = try await D3DMetalInstaller.install(
                    from: source, intoEngine: engine,
                )
                d3dMetalVersion = entry.version
                EventLog.shared.log(.setup, "D3DMetal \(entry.version) added to the engine")
            } catch {
                d3dMetalError = "\(error)"
            }
            isAddingD3DMetal = false
        }
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

/// What the five renderers are, in the order someone would try them.
private struct RendererHelp: View {
    let available: [Renderer]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Choosing a renderer")
                .font(.headline)
            Text("Each one translates the Windows graphics API a game speaks "
                + "into Metal. A game that stutters or refuses to start is "
                + "usually a game on the wrong one.")
                .font(.callout)
                .foregroundStyle(.secondary)
            ForEach(available, id: \.self) { renderer in
                VStack(alignment: .leading, spacing: 1) {
                    Text(renderer.label).font(.callout.weight(.semibold))
                    Text(renderer.guidance)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Changing this takes effect the next time a game starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 380)
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
