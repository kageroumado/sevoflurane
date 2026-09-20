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
    @Binding var selection: String?
    /// The catalog entry chosen while its fetch runs, so the picker shows it
    /// rather than snapping back.
    @State private var pending: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CaptionedRow(caption: detail) {
                Picker("Upscaler", selection: pickerSelection) {
                    if let inherited {
                        Text("Inherit (\(label(forToken: inherited)))").tag("")
                    }
                    ForEach(shaders.choices) { choice in
                        Text(label(for: choice)).tag(choice.token)
                    }
                    if let selection, shaders.choices.allSatisfy({ $0.token != selection }) {
                        // A package the settings name and the store lacks keeps
                        // its row, so the picker never shows an empty selection.
                        Text("\(selection) (not installed)").tag(selection)
                    }
                }
            }
            .disabled(shaders.busy != nil)
            ShaderFetchStatus(shaders: shaders)
        }
        .onAppear { shaders.load() }
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: { pending ?? selection ?? "" },
            set: { token in
                if let entry = shaders.downloadable.first(where: { $0.name == token }) {
                    pending = token
                    Task(name: "Fetch shader package \(token)") {
                        let package = await shaders.install(entry)
                        pending = nil
                        if package != nil { selection = token }
                    }
                    return
                }
                selection = token.isEmpty ? nil : token
            },
        )
    }

    private func label(for choice: ShaderPackages.Choice) -> String {
        guard case let .downloadable(entry) = choice else { return choice.label }
        let size = entry.size.map { " (\(ByteCountFormatter.string(fromByteCount: $0, countStyle: .file)))" } ?? ""
        return "\(entry.title) · Download\(size)"
    }

    private func label(forToken token: String) -> String {
        shaders.choices.first { $0.token == token }?.label ?? token
    }

    /// One line on the current choice — the inherited one's when inheriting.
    private var detail: String {
        let token = pending ?? selection ?? inherited
        guard let token else { return "" }
        guard let choice = shaders.choices.first(where: { $0.token == token }) else {
            return "This package is missing. Games fall back to Lanczos."
        }
        return choice.detail
    }
}

/// The final filter picker both levels share. A `nil` selection is the
/// inherit entry, offered when `inherited` is the level above's value.
struct FinalFilterPicker: View {
    var inherited: FinalFilter?
    @Binding var selection: FinalFilter?

    var body: some View {
        CaptionedRow(caption: (selection ?? inherited)?.detail ?? "") {
            Picker("Final filter", selection: pickerSelection) {
                if let inherited {
                    Text("Inherit (\(inherited.label))").tag("")
                }
                ForEach(FinalFilter.allCases, id: \.self) { filter in
                    Text(filter.label).tag(filter.rawValue)
                }
            }
        }
    }

    private var pickerSelection: Binding<String> {
        Binding(
            get: { selection?.rawValue ?? "" },
            set: { selection = FinalFilter(rawValue: $0) },
        )
    }
}

/// The fetch in flight and the last failure, under whichever control started it.
struct ShaderFetchStatus: View {
    let shaders: ShaderStore

    var body: some View {
        if let busy = shaders.busy {
            HStack(spacing: 8) {
                if let fraction = busy.fraction {
                    ProgressView(value: fraction).frame(width: 120)
                } else {
                    ProgressView().controlSize(.small)
                }
                Text("Downloading \(busy.title)…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        if let error = shaders.error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
