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
    let store: GraphicsStore
    let highlighted: String?
    @State private var showingRendererHelp = false
    @State private var d3dMetalError: String?
    @State private var isAddingD3DMetal = false

    /// Edits go through the store, which decides whether they reach a bottle.
    private var graphics: Binding<BottleGraphics.Selection> {
        Binding(get: { store.selection }, set: { store.update($0) })
    }

    var body: some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Picker("Game renderer", selection: graphics.renderer) {
                            ForEach(store.availableRenderers, id: \.self) { renderer in
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
                            RendererHelp(available: store.availableRenderers)
                        }
                    }
                    Text(store.selection.renderer.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.renderer", highlighted: highlighted)
                VStack(alignment: .leading, spacing: 4) {
                    Picker("Report the GPU as", selection: graphics.gpu) {
                        ForEach(GPUIdentity.allCases, id: \.self) { identity in
                            Text(identity.label).tag(identity)
                        }
                    }
                    Text(store.selection.gpu.detail)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .highlightable(id: "graphics.gpu", highlighted: highlighted)
                Toggle(isOn: graphics.msync) {
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
            if store.managedEngine != nil { d3dMetalSection }
        }
        .formStyle(.grouped)
    }

    /// Apple's Game Porting Toolkit is not ours to ship, so a managed engine
    /// gets D3DMetal from the user's own download — the arrangement Whisky
    /// uses. Releases and betas install side by side; the newest is used
    /// unless another is chosen here.
    private var d3dMetalSection: some View {
        Section {
            if store.d3dMetalVersions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Add D3DMetal").font(.callout.weight(.semibold))
                    Text("Direct3D 12 needs Apple's Game Porting Toolkit, which only "
                        + "Apple may distribute. Download it from developer.apple.com "
                        + "and point Sevoflurane at the disk image.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                Picker("D3DMetal version", selection: Binding(
                    get: { store.activeD3DMetal },
                    set: { chosen in chosen.map(store.chooseD3DMetal) },
                )) {
                    ForEach(store.d3dMetalVersions, id: \.version) { entry in
                        Text(entry.version).tag(Optional(entry.version))
                    }
                }
            }
            HStack {
                if let d3dMetalError {
                    Text(d3dMetalError).font(.callout).foregroundStyle(.orange)
                }
                Spacer()
                Button(store.d3dMetalVersions.isEmpty
                    ? "Choose Toolkit…" : "Add Another Version…") {
                        addD3DMetal()
                    }
                    .disabled(isAddingD3DMetal)
            }
        } header: {
            Text("Apple's Game Porting Toolkit")
        }
    }

    private func addD3DMetal() {
        let panel = NSOpenPanel()
        panel.message = "Choose the Game Porting Toolkit disk image you downloaded."
        panel.allowedContentTypes = [.diskImage]
        panel.canChooseDirectories = true
        guard panel.runModal() == .OK, let source = panel.url else { return }
        isAddingD3DMetal = true
        d3dMetalError = nil
        Task(name: "Install D3DMetal") {
            d3dMetalError = await store.installD3DMetal(from: source)
            isAddingD3DMetal = false
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
