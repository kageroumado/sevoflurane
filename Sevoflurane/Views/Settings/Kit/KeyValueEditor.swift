import SwiftUI

/// One editor for a table of names and values: DLL overrides and environment
/// variables, a bottle's and a game's. Each saved entry is a row with its
/// value editable in place and a trash in the accessory slot; the last row
/// holds bordered fields and Add. A value from a fixed set starts on the set's
/// initial choice and is changed on its saved row, so the input row is the
/// same in a wide pane and a narrow one.
struct KeyValueEditor: View {
    struct Entry: Identifiable, Equatable {
        let key: String
        let value: String

        var id: String { key }
    }

    /// How a value is edited.
    enum Values {
        case text(prompt: String)
        /// One of a fixed set; a new entry starts on `initial`.
        case choices([SettingChoice], initial: String)
    }

    /// What the editor asks of the table it edits.
    struct Rules {
        /// A typed key as it is stored.
        var normalize: (String) -> String = { $0.trimmingCharacters(in: .whitespaces) }
        /// Why a pair cannot be stored.
        var problem: (_ key: String, _ value: String) -> String? = { _, _ in nil }
        /// What storing a key means beyond itself, as its row's caption.
        var remark: (_ key: String) -> String? = { _ in nil }
        /// The trash button's label for a key.
        var removeLabel: (_ key: String) -> String
    }

    let entries: [Entry]
    let values: Values
    /// Drawn between a key and its value.
    var separator = ""
    let keyPrompt: String
    /// Names the key field completes as you type.
    var completions: [String] = []
    let rules: Rules
    /// Stores a value under a key; `nil` removes the key.
    let set: (_ key: String, _ value: String?) -> Void

    var body: some View {
        ForEach(entries) { entry in
            KeyValueRow(entry: entry, values: values, separator: separator, rules: rules, set: set)
        }
        KeyValueInput(
            existing: Set(entries.map(\.key)), values: values, separator: separator, keyPrompt: keyPrompt,
            completions: completions, rules: rules, set: set,
        )
    }
}

/// A saved entry.
private struct KeyValueRow: View {
    let entry: KeyValueEditor.Entry
    let values: KeyValueEditor.Values
    let separator: String
    let rules: KeyValueEditor.Rules
    let set: (String, String?) -> Void
    @State private var draft = ""

    var body: some View {
        SettingsRow(
            title: "\(entry.key + separator)",
            caption: rules.remark(entry.key) ?? "",
            state: .failure(ifPresent: problem),
            titleIsCode: true,
        ) {
            KeyValueControl(title: "\(entry.key)", values: values, stored: entry.value, value: value, commit: commit)
        } accessory: {
            SettingsAccessoryButton(symbol: "trash", label: rules.removeLabel(entry.key)) {
                // Reset the draft first, or the row's disappearance would
                // store the unsaved edit and bring the entry back.
                draft = entry.value
                set(entry.key, nil)
            }
        }
        .onAppear { draft = entry.value }
        .onChange(of: entry.value) { _, stored in draft = stored }
        .onDisappear(perform: commit)
    }

    /// A field edits a draft and stores it when the edit ends; a pop-up stores
    /// its choice at once.
    private var value: Binding<String> {
        if case .text = values { return $draft }
        return Binding(get: { entry.value }, set: { set(entry.key, $0) })
    }

    /// Why the edited value cannot be stored.
    private var problem: String? {
        draft == entry.value ? nil : rules.problem(entry.key, draft)
    }

    private func commit() {
        guard draft != entry.value, rules.problem(entry.key, draft) == nil else { return }
        set(entry.key, draft)
    }
}

/// The row that adds an entry.
private struct KeyValueInput: View {
    let existing: Set<String>
    let values: KeyValueEditor.Values
    let separator: String
    let keyPrompt: String
    let completions: [String]
    let rules: KeyValueEditor.Rules
    let set: (String, String?) -> Void
    @State private var name = ""
    /// The typed or chosen value; `nil` until then, which a fixed set reads
    /// as its initial choice.
    @State private var typed: String?

    var body: some View {
        SettingsRow(
            title: nil,
            caption: rules.remark(key) ?? "",
            state: .failure(ifPresent: key.isEmpty ? nil : problem),
        ) {
            keyField
            if case .text = values {
                if !separator.isEmpty {
                    Text(verbatim: separator).font(SettingsType.code)
                }
                KeyValueControl(title: "Value", values: values, stored: nil, value: value, commit: submit)
            }
            Button(existing.contains(key) ? "Replace" : "Add", action: submit)
                .disabled(key.isEmpty || problem != nil)
        }
    }

    private var value: Binding<String> {
        Binding(get: { typed ?? initial }, set: { typed = $0 })
    }

    @ViewBuilder private var keyField: some View {
        if completions.isEmpty {
            TextField("Name", text: $name, prompt: Text(verbatim: keyPrompt))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(SettingsType.code)
                .frame(maxWidth: SettingsMetrics.keyField)
                .onSubmit(submit)
        } else {
            SettingsComboField(text: $name, completions: completions, prompt: keyPrompt)
        }
    }

    private var key: String { rules.normalize(name) }

    private var problem: String? { rules.problem(key, value.wrappedValue) }

    private var initial: String {
        if case let .choices(_, initial) = values { initial } else { "" }
    }

    private func submit() {
        guard !key.isEmpty, problem == nil else { return }
        set(key, value.wrappedValue)
        name = ""
        typed = nil
    }
}

/// A value's control: a bordered field, or a pop-up over the fixed choices.
private struct KeyValueControl: View {
    let title: LocalizedStringResource
    let values: KeyValueEditor.Values
    /// The value on disk, which keeps a choice of its own when the fixed set
    /// lacks it.
    let stored: String?
    @Binding var value: String
    let commit: () -> Void

    var body: some View {
        switch values {
        case let .text(prompt):
            TextField(text: $value, prompt: Text(verbatim: prompt)) { Text(title) }
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(SettingsType.code)
                .frame(minWidth: SettingsMetrics.numberField)
                .onSubmit(commit)
        case let .choices(choices, _):
            SettingsPopUp(title: title, selection: $value) {
                ForEach(choices) { choice in
                    Text(choice.label).tag(choice.value)
                }
                if let stored, !choices.contains(where: { $0.value == stored }) {
                    Text(verbatim: stored).tag(stored)
                }
            }
        }
    }
}
