import AppKit
import Propofol
import SwiftUI

/// The panel that opens when a Windows program is handed to Sevoflurane:
/// dropped on the app, opened with it from Finder, or picked from the menu bar.
@MainActor
final class AdoptionPanel {
    static let shared = AdoptionPanel()

    private let panel = DialogPanel(
        size: NSSize(width: AdoptionView.width, height: 240), title: String(localized: "Open in Sevoflurane"),
    )

    /// Shows the panel for one executable, replacing whatever it was showing.
    func present(_ url: URL) {
        let model = AdoptionModel(url: url)
        model.onFinish = { [panel] in panel.dismiss() }
        panel.show(AdoptionView(model: model))
    }
}

// MARK: - The view

private struct AdoptionView: View {
    @Bindable var model: AdoptionModel

    /// Wide enough for the three program actions on one row in English.
    static let width: CGFloat = 500

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.md) {
            header
            switch model.stage {
            case .choosing:
                verdict
                if !model.isInstaller { nameField }
                Text(model.destination)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
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
        .frame(width: Self.width)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// Which program this is: the name it gives itself, then the file, which
    /// is the fact. A download can call itself anything.
    private var header: some View {
        HStack(alignment: .center, spacing: Theme.Space.md) {
            Group {
                if let icon = model.icon {
                    Image(nsImage: icon).resizable()
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.tertiary)
                }
            }
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(model.title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    if let version = model.version {
                        Text(version)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .layoutPriority(-1)
                    }
                }
                Text(model.location)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
    }

    /// What Sevoflurane takes the file for, when that is more than "a
    /// program", with the way to say otherwise beside it: a correction, so
    /// it sits with the claim and not among the actions.
    @ViewBuilder private var verdict: some View {
        if model.isOverruled {
            Toggle("Remember that this file is not an installer", isOn: $model.remembersOverrule)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))
        } else if model.verdict.kind != ProgramKind.program {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
                    verdictText
                    correction
                }
                VStack(alignment: .leading, spacing: 2) {
                    verdictText.fixedSize(horizontal: false, vertical: true)
                    correction
                }
            }
        }
    }

    private var verdictText: some View {
        Text(model.verdict.summary).font(.system(size: 12))
    }

    @ViewBuilder private var correction: some View {
        if model.isInstaller {
            Button("Not an Installer") { model.overruleInstaller() }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .help("Choose whether to play it once or add it to Quick Launch.")
        }
    }

    /// The name the program gets in Quick Launch.
    private var nameField: some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.Space.sm) {
            Text("Name").font(.system(size: 12))
            TextField("Name", text: $model.name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .labelsHidden()
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

    /// One row when every label fits whole, otherwise a column: a label is
    /// never cut, in any language.
    private var choices: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: Theme.Space.sm) {
                cancel
                Spacer(minLength: Theme.Space.md)
                actions
            }
            VStack(spacing: Theme.Space.sm) {
                actions
                cancel
            }
            .frame(maxWidth: .infinity)
        }
    }

    private var cancel: some View {
        Button("Cancel") { model.cancel() }
            .keyboardShortcut(.cancelAction)
            .fixedSize()
    }

    /// The default action comes last, as in an alert.
    @ViewBuilder private var actions: some View {
        if model.isInstaller {
            Button("Run Once") { model.playOnce() }
                .fixedSize()
            Button("Install into Bottle") { model.install() }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
        } else {
            Button("Play Once") { model.playOnce() }
                .fixedSize()
            Button("Add to Quick Launch") { model.adopt(andPlay: false) }
                .fixedSize()
            Button("Add and Play") { model.adopt(andPlay: true) }
                .keyboardShortcut(.defaultAction)
                .fixedSize()
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
