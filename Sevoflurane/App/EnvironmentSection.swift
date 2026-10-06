import Propofol
import SwiftUI

/// The variables a level sets by name (``UserEnvironment``): one row per
/// variable with its value and a remove button, then a row that adds one.
/// Settings › Engine shows the bottle's, Settings › Games a game's.
struct EnvironmentSection: View {
    let store: SettingsStore

    var body: some View {
        let table = (store.values.environment ?? [:]).sorted { $0.key < $1.key }
        Section {
            ForEach(table, id: \.key) { name, value in
                EnvironmentRow(name: name, value: value) {
                    store.send(.setEnvironment(name: name, value: $0))
                }
            }
            AddEnvironmentRow(existing: Set(table.map(\.key))) { name, value in
                store.send(.setEnvironment(name: name, value: value))
            }
        } header: {
            HStack(spacing: 6) {
                Text("Environment")
                SettingHelpButton(help: SettingCopy.environment)
            }
        } footer: {
            Text(footer)
        }
    }

    private var footer: LocalizedStringResource {
        switch store.level {
        case .game:
            "For this game alone, from its next launch, over Settings › Engine's. Steam's launch options can set these too: KEY=VALUE %command%."
        case .bottle:
            "For every game, from its next launch. Settings › Games adds a game's own."
        }
    }
}

/// One variable: its name, its value to edit in place, the setting it
/// overrides when a row also writes that name, and the button that removes it.
private struct EnvironmentRow: View {
    let name: String
    let value: String
    /// Stores a new value; `nil` removes the variable.
    let set: (String?) -> Void
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                Text(verbatim: "\(name)=").font(.body.monospaced())
                TextField("Value", text: $draft, prompt: Text("empty removes it"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit(commit)
                Button {
                    // An unsaved edit would otherwise be stored by the
                    // row's disappearance, bringing the variable back.
                    draft = value
                    set(nil)
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove \(name)")
                .accessibilityLabel("Remove \(name)")
            }
            if let problem = UserEnvironment.problem(name: name, value: draft), draft != value {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            } else if let setting = UserEnvironment.managingSetting(of: name) {
                Text("Takes the place of the \(setting) setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, stored in draft = stored }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard draft != value, UserEnvironment.problem(name: name, value: draft) == nil else { return }
        set(draft)
    }
}

/// The row that names a variable and its value and adds the pair.
private struct AddEnvironmentRow: View {
    let existing: Set<String>
    let add: (_ name: String, _ value: String) -> Void
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.xs) {
            HStack {
                TextField("Name", text: $name, prompt: Text(verbatim: "DXVK_HUD"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .frame(maxWidth: 180)
                    .onSubmit(submit)
                Text(verbatim: "=").font(.body.monospaced())
                TextField("Value", text: $value, prompt: Text(verbatim: "1"))
                    .labelsHidden()
                    .font(.body.monospaced())
                    .onSubmit(submit)
                Button(existing.contains(trimmedName) ? "Replace" : "Add", action: submit)
                    .disabled(trimmedName.isEmpty || problem != nil)
            }
            if !trimmedName.isEmpty, let problem {
                Text(problem.message).font(.caption).foregroundStyle(.red)
            } else if let setting = UserEnvironment.managingSetting(of: trimmedName) {
                Text("Takes the place of the \(setting) setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var trimmedName: String { name.trimmingCharacters(in: .whitespaces) }

    private var problem: UserEnvironment.Problem? {
        UserEnvironment.problem(name: trimmedName, value: value)
    }

    private func submit() {
        guard !trimmedName.isEmpty, problem == nil else { return }
        add(trimmedName, value)
        name = ""
        value = ""
    }
}
