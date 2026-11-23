#if DEBUG
    import SwiftUI

    /// Every piece of the Settings kit in every state, so a piece can be looked
    /// at alone. The strings are the gallery's own and are never translated.
    struct SettingsKitGallery: View {
        /// What the gallery's controls edit.
        private struct Values {
            var isOn = true
            var choice = "b"
            var inherited: String?
            var text = ""
            var number = 5200
            var checks: Set<String> = ["a"]
            var variables = [
                KeyValueEditor.Entry(key: "DXVK_HUD", value: "fps"),
                KeyValueEditor.Entry(key: "WINEDEBUG", value: "-all"),
            ]
            var overrides = [KeyValueEditor.Entry(key: "dinput8", value: "n,b")]
        }

        @State private var values = Values()

        private static let help = SettingHelp(
            title: "A row's help",
            summary: "The mechanism, the exceptions and when to change the setting.",
            entries: [.init(name: "A term", text: "What the term means.")],
            footnote: "The small print.",
        )
        private static let failure = "The installer exited with status 1."

        var body: some View {
            SettingsForm(highlighted: nil) {
                toggles
                pickers
                actions
                readouts
                states
                editors
                SettingsSection(
                    title: "Section", heading: "Heading", help: Self.help, value: "12.4 GB", isWorking: true,
                    footer: "A footer says what the card is for.", reach: .nextLaunch,
                ) {
                    SettingsMessage(text: "A message fills a card that has nothing else to show.")
                    SettingsJump(title: "Jump", caption: "Goes to another setting.", target: .engineDependencies)
                    SettingsDisclosure(title: "Disclosure") {
                        SettingsCodeBlock(text: "{\n  \"frames\": 60\n}")
                    }
                    SettingsCode(title: "Code", code: "/usr/local/bin/sevo mcp")
                }
            }
        }

        private var toggles: some View {
            SettingsSection(title: "SettingsToggle", reach: .clientRestart) {
                SettingsToggle(title: "Normal", isOn: $values.isOn)
                SettingsToggle(title: "With a caption", caption: "One line on what it changes.", isOn: $values.isOn)
                SettingsToggle(title: "With help", caption: "One line on what it changes.", help: Self.help, isOn: $values.isOn)
                SettingsToggle(title: "Warning", state: .warning("Works, with something to know."), isOn: $values.isOn)
                SettingsToggle(title: "Failure", state: .failure(Self.failure), help: Self.help, isOn: $values.isOn)
                SettingsToggle(title: "Working", caption: "Connecting…", isWorking: true, isOn: $values.isOn)
                SettingsToggle(title: "Disabled", caption: "One line on what it changes.", isOn: $values.isOn)
                    .disabled(true)
                SettingsToggle(
                    title: "With a note",
                    note: SettingsRowNote(text: "Set by a known fix", actionTitle: "Undo", reason: "Why it was set.") {},
                    isOn: $values.isOn,
                )
            }
        }

        private var pickers: some View {
            SettingsSection(title: "SettingsPicker and InheritablePicker") {
                SettingsPicker(title: "Normal", selection: $values.choice) { options }
                SettingsPicker(
                    title: "With a caption and help", caption: "What the chosen value does.", help: Self.help,
                    selection: $values.choice,
                ) { options }
                SettingsPicker(title: "With a menu", caption: "What the chosen value does.", selection: $values.choice) {
                    options
                } accessory: {
                    SettingsAccessoryMenu { Button("An action") {} }
                }
                SettingsPicker(title: "Failure with a menu", state: .failure(Self.failure), selection: $values.choice) {
                    options
                } accessory: {
                    SettingsAccessoryMenu { Button("An action") {} }
                }
                SettingsPicker(title: "Working", caption: "Downloading…", isWorking: true, selection: $values.choice) { options }
                SettingsPicker(title: "Disabled", selection: $values.choice) { options }
                    .disabled(true)
                InheritablePicker(
                    title: "Inheritable", caption: "The setting\u{2019}s own description.", help: Self.help,
                    inherited: "Second", selection: $values.inherited,
                ) { options }
            }
        }

        @ViewBuilder private var options: some View {
            Text("First").tag("a")
            Text("Second").tag("b")
            Text("A longer third choice").tag("c")
        }

        private var actions: some View {
            SettingsSection(title: "SettingsAction") {
                SettingsAction(title: "Normal") { Button("Do the Thing") {} }
                SettingsAction(title: "With a caption", caption: "When to press it.") { Button("Do the Thing") {} }
                SettingsAction(title: "With help", caption: "When to press it.", help: Self.help) {
                    Button("Choose…") {}
                }
                SettingsAction(title: "Two buttons", caption: "When to press them.") {
                    Button("Revert") {}
                    Button("Switch") {}.buttonStyle(.borderedProminent)
                }
                SettingsAction(title: "A value and a button", caption: "When to press it.") {
                    SettingsValueText(text: "154.62 GB")
                    Button("Link") {}
                } accessory: {
                    SettingsAccessoryLink(label: "Project website", destination: URL(string: "https://kagerou.glass")!)
                }
                SettingsAction(title: "Warning", state: .warning("Required. What it fixes.")) {
                    Button("Install (8 MB)") {}
                }
                SettingsAction(title: "Failure", state: .failure(Self.failure)) { Button("Try Again") {} }
                SettingsAction(title: "Working", caption: "Installing…", isWorking: true) {
                    Button("Do the Thing") {}.disabled(true)
                }
                SettingsAction(title: "Done") { SettingsStatus(.done, "Installed") }
                SettingsAction(title: "Disabled", caption: "When to press it.") { Button("Do the Thing") {} }
                    .disabled(true)
            }
        }

        private var readouts: some View {
            SettingsSection(title: "SettingsValue, SettingsField, SettingsChecks, SettingsProgress") {
                SettingsValue(title: "Value", value: "214.86 GB")
                SettingsValue(title: "Code", value: "err+all,+pid", isCode: true)
                SettingsValue(
                    title: "Marked, with a button", value: "6.87 GB", caption: "What it holds.", mark: .dot(.orange),
                ) {
                    SettingsAccessoryButton(symbol: "trash", label: "Move to the Trash") {}
                }
                SettingsValue(
                    title: "Marked, with a warning", value: "1 game · 71.94 GB",
                    state: .warning("Games on this drive can fail."), mark: .symbol("externaldrive"),
                )
                SettingsField(title: "Field", caption: "What the text is for.", prompt: "Player", text: $values.text)
                SettingsField(title: "Field with a button", text: $values.text) { Button("Use Name") {} }
                SettingsNumberField(title: "Number", value: $values.number, range: 0 ... 1_000_000)
                SettingsChecks(title: "Checks", options: [("a", "English"), ("b", "Japanese")], selection: $values.checks)
                SettingsProgress(title: "Downloading", fraction: 0.4, caption: "3.2 GB / 5.1 GB") {}
                SettingsProgress(title: "Starting…")
            }
        }

        private var states: some View {
            SettingsSection(title: "SettingsNotice") {
                SettingsNotice(.done, "Done, in the label color.")
                SettingsNotice(.warning, "A warning, in the label color.")
                SettingsNotice(.failure, "A failure, in the label color.")
                SettingsNotice(.working, "Working…")
            }
        }

        @ViewBuilder private var editors: some View {
            SettingsSection(title: "KeyValueEditor, text", help: Self.help) {
                KeyValueEditor(
                    entries: values.variables, values: .text(prompt: "1"), separator: "=", keyPrompt: "DXVK_HUD",
                    rules: .init(removeLabel: { "Remove \($0)" }),
                ) { key, value in
                    store(key, value, in: &values.variables)
                }
            }
            SettingsSection(title: "KeyValueEditor, choices") {
                KeyValueEditor(
                    entries: values.overrides, values: .choices(DLLOverrideEditing.gameOrders, initial: "n,b"),
                    keyPrompt: DLLOverrideEditing.prompt, completions: ["d3d9", "dinput8", "version"],
                    rules: DLLOverrideEditing.rules,
                ) { key, value in
                    store(key, value, in: &values.overrides)
                }
            }
        }

        private func store(_ key: String, _ value: String?, in entries: inout [KeyValueEditor.Entry]) {
            entries.removeAll { $0.key == key }
            if let value { entries.append(.init(key: key, value: value)) }
            entries.sort { $0.key < $1.key }
        }
    }
#endif
