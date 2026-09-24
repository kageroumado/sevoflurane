import Propofol
import SwiftUI

/// The bottle's renderer, in the footer: every renderer by its short name in
/// equal segments, the chosen one on the accent pill. Nothing moves under the
/// pointer, so a segment stays where it was aimed at. A change reaches the
/// next game launched from the menu bar, which restages the renderer or
/// restarts the client for it; each game row says so under its name until
/// then.
struct RendererPicker: View {
    let graphics: GraphicsStore

    /// Automatic defers to CrossOver's per-game database; it is offered here
    /// only while it is the choice, and chosen in Settings.
    private var options: [(value: Renderer, label: String)] {
        let current = graphics.selection.renderer
        return graphics.availableRenderers
            .filter { $0 != .auto || $0 == current }
            .map { ($0, $0.shortLabel) }
    }

    private var selection: Binding<Renderer> {
        Binding(
            get: { graphics.selection.renderer },
            set: { renderer in
                var selection = graphics.selection
                selection.renderer = renderer
                graphics.update(selection)
            },
        )
    }

    var body: some View {
        if options.count > 1 {
            let chosen = graphics.selection.renderer
            PillPicker(
                title: String(localized: "Game renderer"),
                options: options,
                selection: selection,
                height: Theme.footerControlHeight,
                font: .system(size: 11),
                onTint: Theme.onAccent,
            )
            .frame(maxWidth: .infinity)
            .help("\(chosen.label) · \(chosen.detail)\n\(graphics.engineName)")
            // PillPicker's own stand-in is a titled menu picker, which reaches
            // the tree as a caption beside an unnamed pop-up. A named radio
            // group instead, with the renderers' full names.
            .accessibilityRepresentation {
                Picker(selection: selection) {
                    ForEach(options, id: \.value) { option in
                        Text(verbatim: option.value.label).tag(option.value)
                    }
                } label: {
                    Text("Game renderer")
                }
                .labelsHidden()
            }
        }
    }
}

private extension Renderer {
    /// The name as a quarter of the footer's free width holds it.
    var shortLabel: String {
        switch self {
        case .auto: String(localized: "Auto", comment: "Automatic renderer, in a narrow segment")
        case .d3dmetal: "D3DM"
        case .dxmt, .dxvk: label
        case .wined3d: String(localized: "Wine", comment: "Wine's built-in renderer, in a narrow segment")
        }
    }
}
