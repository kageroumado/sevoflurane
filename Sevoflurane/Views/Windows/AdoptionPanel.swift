import AppKit
import Propofol
import SwiftUI

/// The panel that opens when a Windows program is handed to Sevoflurane:
/// dropped on the app, opened with it from Finder, or picked from the menu bar.
@MainActor
final class AdoptionPanel {
    static let shared = AdoptionPanel()

    private var panel: NSPanel?

    /// Shows the panel for one executable, replacing whatever it was showing.
    func present(_ url: URL) {
        let model = AdoptionModel(url: url)
        model.onFinish = { [weak self] in self?.close() }
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.contentView = NSHostingView(rootView: AdoptionView(model: model))
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 420, height: 260))
        panel.center()
        // The app has no activation of its own, so the panel would open behind
        // whatever the user was in.
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func close() {
        panel?.orderOut(nil)
        panel?.contentView = nil
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 260),
            styleMask: [.titled, .closable, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false,
        )
        panel.title = String(localized: "Open in Sevoflurane")
        panel.titlebarAppearsTransparent = true
        panel.isFloatingPanel = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        return panel
    }
}

// MARK: - The view

private struct AdoptionView: View {
    @Bindable var model: AdoptionModel

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            switch model.stage {
            case .choosing:
                Text(model.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if model.isOverruled {
                    Toggle("Remember for this file", isOn: $model.remembersOverrule)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 11))
                }
                choices
            case .installing:
                progress
            case let .installed(root, executables):
                InstalledStep(model: model, root: root, executables: executables)
            case let .failed(reason):
                Text(reason).font(.system(size: 12)).foregroundStyle(.orange)
                HStack {
                    Spacer()
                    Button("Close") { model.cancel() }
                }
            }
        }
        .padding(Theme.Space.lg)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.Space.md) {
            Group {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 64, height: 64)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Name", text: $model.name)
                    .textFieldStyle(.plain)
                    .font(.system(size: 15, weight: .semibold))
                if let subtitle = model.subtitle {
                    Text(subtitle)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(model.verdict.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    private var progress: some View {
        HStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.small)
            Text("Installing into the bottle. The next step lists what was added.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
    }

    private var choices: some View {
        HStack(spacing: Theme.Space.sm) {
            Button("Cancel") { model.cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            if model.isInstaller {
                Button("Not an Installer") { model.overruleInstaller() }
                    .help("Choose whether to play it once or add it to Quick Launch.")
                Button("Run Once") { model.playOnce() }
                Button("Install into Bottle") { model.install() }
                    .keyboardShortcut(.defaultAction)
            } else {
                Button("Play Once") { model.playOnce() }
                Button("Add to Quick Launch") { model.adopt(andPlay: false) }
                Button("Add and Play") { model.adopt(andPlay: true) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}

/// The installer's second step: what it left in the bottle, and which of it
/// gets a Quick Launch entry.
private struct InstalledStep: View {
    @Bindable var model: AdoptionModel
    let root: URL?
    let executables: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            Text(summary)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
            if !executables.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(executables, id: \.self) { exe in
                            Toggle(isOn: $model[keeps: exe]) {
                                Text(exe.lastPathComponent).font(.system(size: 12))
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 140)
            }
            HStack {
                Button("Close") { model.cancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add to Quick Launch") { model.adoptChosen(installedRoot: root) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.chosen.isEmpty)
            }
        }
    }

    private var summary: String {
        guard let root else { return InterfaceCopy.localized("Sevoflurane found nothing the installer added.") }
        return executables.isEmpty
            ? String(localized: "It installed \(root.lastPathComponent). No program inside it can start.")
            : String(localized: "It installed \(root.lastPathComponent). Pick what to keep.")
    }
}
