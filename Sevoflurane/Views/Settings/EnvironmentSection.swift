import Propofol
import SwiftUI

/// The variables a level sets by name (``UserEnvironment``): one editable row
/// each, then a row that adds one. Settings › Engine shows the bottle's,
/// Settings › Games a game's.
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
            "For this game alone, from its next launch, over Settings › Engine's."
        case .bottle:
            "For every game, from its next launch. Settings › Games adds a game's own."
        }
    }
}

/// One variable: its name, its value edited in place, the setting it overrides,
/// and its remove button.
private struct EnvironmentRow: View {
    let name: String
    let value: String
    /// Stores a new value; `nil` removes the variable.
    let set: (String?) -> Void
    @State private var draft = ""

    var body: some View {
        SettingsRow(caption: problem ?? managed ?? "", isWarning: problem != nil) {
            Text(verbatim: "\(name)=").font(.body.monospaced())
            TextField("Value", text: $draft, prompt: Text("empty removes it"))
                .labelsHidden()
                .font(.body.monospaced())
                .onSubmit(commit)
        } accessory: {
            Button {
                // Reset the draft first, or the row's disappearance would
                // store the unsaved edit and bring the variable back.
                draft = value
                set(nil)
            } label: {
                Image(systemName: "minus.circle")
            }
            .help("Remove \(name)")
            .accessibilityLabel("Remove \(name)")
        }
        .onAppear { draft = value }
        .onChange(of: value) { _, stored in draft = stored }
        .onDisappear(perform: commit)
    }

    /// Why the edited value cannot be stored.
    private var problem: String? {
        draft == value ? nil : UserEnvironment.problem(name: name, value: draft)?.message
    }

    private var managed: String? {
        UserEnvironment.managingSetting(of: name).map {
            String(localized: "Takes the place of the \($0) setting.")
        }
    }

    private func commit() {
        guard draft != value, UserEnvironment.problem(name: name, value: draft) == nil else { return }
        set(draft)
    }
}

private struct AddEnvironmentRow: View {
    let existing: Set<String>
    let add: (_ name: String, _ value: String) -> Void
    @State private var name = ""
    @State private var value = ""

    var body: some View {
        SettingsRow(caption: caption, isWarning: !trimmedName.isEmpty && problem != nil) {
            TextField("Name", text: $name, prompt: Text(verbatim: "DXVK_HUD"))
                .labelsHidden()
                .font(.body.monospaced())
                .frame(maxWidth: Self.nameWidth)
                .onSubmit(submit)
            Text(verbatim: "=").font(.body.monospaced())
            TextField("Value", text: $value, prompt: Text(verbatim: "1"))
                .labelsHidden()
                .font(.body.monospaced())
                .onSubmit(submit)
            Button(existing.contains(trimmedName) ? "Replace" : "Add", action: submit)
                .disabled(trimmedName.isEmpty || problem != nil)
        }
    }

    /// The name field's width, which holds the longest variable a fix names.
    private static let nameWidth: CGFloat = 180

    private var caption: String {
        if !trimmedName.isEmpty, let problem { return problem.message }
        return UserEnvironment.managingSetting(of: trimmedName).map {
            String(localized: "Takes the place of the \($0) setting.")
        } ?? ""
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
