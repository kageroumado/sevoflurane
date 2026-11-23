import SwiftUI

/// The upscaler picker both levels of Settings share: the fixed choices, the
/// installed packages, then the packages that can be fetched, which are
/// fetched when chosen and become the value once they land. A `nil`
/// selection is the inherit entry, offered when `inherited` names what the
/// level above resolves to.
struct UpscalerPicker: View {
    let shaders: ShaderStore
    /// The level above's value, as stored; `nil` at the bottle level, which
    /// the picker cannot make inherit.
    var inherited: String?
    var note: SettingsRowNote?
    @Binding var selection: String?
    /// The catalog entry chosen while its fetch runs, so the picker shows it
    /// rather than snapping back.
    @State private var pending: String?

    var body: some View {
        Group {
            if let inherited {
                InheritablePicker(
                    title: "Upscaler", caption: detail, state: state, help: SettingCopy.scaling, note: note,
                    inherited: label(of: inherited),
                    selection: Binding(get: { pending ?? selection }, set: choose),
                ) {
                    options
                }
            } else {
                SettingsPicker(
                    title: "Upscaler", caption: detail, state: state, help: SettingCopy.scaling, note: note,
                    selection: Binding(get: { pending ?? selection ?? "" }, set: choose),
                ) {
                    options
                }
            }
        }
        .disabled(shaders.busy != nil)
        .onAppear { shaders.load() }
        ShaderFetchStatus(shaders: shaders)
    }

    @ViewBuilder private var options: some View {
        ForEach(shaders.choices) { choice in
            Text(label(for: choice)).tag(choice.token)
        }
        if let selection, shaders.choices.allSatisfy({ $0.token != selection }) {
            // A package the settings name and the store lacks keeps its row,
            // so the picker never shows an empty selection.
            Text("\(selection) (not installed)").tag(selection)
        }
    }

    /// Stores a choice; one that has to be fetched first becomes the value
    /// when it lands.
    private func choose(_ token: String?) {
        if let token, let entry = shaders.downloadable.first(where: { $0.name == token }) {
            pending = token
            Task(name: "Fetch shader package \(token)") {
                let package = await shaders.install(entry)
                pending = nil
                if package != nil { selection = token }
            }
            return
        }
        selection = token
    }

    private func label(for choice: ShaderPackages.Choice) -> String {
        guard case let .downloadable(entry) = choice else { return choice.label }
        let size = entry.size.map { " (\($0.formatted(.byteCount(style: .file))))" } ?? ""
        return "\(entry.title) · \(InterfaceCopy.localized("Download"))\(size)"
    }

    /// A stored value in the words its menu item uses.
    private func label(of token: String) -> String {
        shaders.choices.first { $0.token == token }?.label ?? token
    }

    private var current: ShaderPackages.Choice? {
        guard let token = pending ?? selection ?? inherited else { return nil }
        return shaders.choices.first { $0.token == token }
    }

    /// One line on the choice in force.
    private var detail: String {
        current?.detail ?? ""
    }

    private var state: SettingsRowState {
        guard current == nil, (pending ?? selection ?? inherited) != nil else { return .normal }
        return .warning(String(localized: "This package is missing. Games fall back to Lanczos."))
    }
}

/// The fetch in flight and the last failure, under whichever control started it.
struct ShaderFetchStatus: View {
    let shaders: ShaderStore

    var body: some View {
        if let busy = shaders.busy {
            SettingsProgress(title: String(localized: "Downloading \(busy.title)…"), fraction: busy.fraction)
        }
        if let error = shaders.error {
            SettingsNotice(.failure, error)
        }
    }
}
