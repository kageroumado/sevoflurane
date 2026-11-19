import AppKit
import Propofol
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Streamer Mode

/// The Streamer Mode switch, and the name and picture Steam's windows show in
/// the account's place while it is on.
struct StreamerModeSection: View {
    let steam: SteamActions?
    let highlighted: SettingsAnchor?
    @AppStorage(StreamerMode.isOnKey, store: Preferences.shared) private var isOn = false
    @State private var store = StreamerModeStore()

    var body: some View {
        @Bindable var store = store
        Section {
            VStack(alignment: .leading, spacing: 2) {
                Toggle("Streamer Mode", isOn: Binding(
                    get: { isOn },
                    set: { enabled in
                        StreamerMode.isOn = enabled
                        steam?.applyStreamerMode()
                    },
                ))
                .toggleStyle(.switch)
                Text("Hides your Steam name, picture, wallet balance and friends in every Steam window, for recording and streaming.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Text("Friends appear as AI models such as Claude, ChatGPT and Gemini.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .highlightable(.generalStreamerMode, highlighted: highlighted)
            TextField("Display name", text: $store.name, prompt: Text(verbatim: StreamerMode.defaultDisplayName))
                .onSubmit(commitName)
                .onChange(of: store.name) { store.storeName() }
            pictureRow
        }
        .onAppear { store.load() }
    }

    private var pictureRow: some View {
        HStack(spacing: Theme.Space.md) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Avatar")
                Text(store.hasPicture ? "Shown in place of your Steam avatar." : "A monogram of the display name.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                if let pictureFailure = store.pictureFailure {
                    Text(pictureFailure).font(.callout).foregroundStyle(.orange)
                }
            }
            Spacer()
            StreamerPicturePreview(name: StreamerMode.resolvedName(store.name), picture: store.picture)
            if store.hasPicture {
                Button("Use Monogram") {
                    store.removePicture()
                    pictureChanged()
                }
            }
            Button("Choose…") { choosePicture() }
        }
    }

    /// The name reaches Steam's pages with the next reload; with the mode on,
    /// that is now.
    private func commitName() {
        store.storeName()
        if isOn { steam?.applyStreamerMode() }
    }

    private func choosePicture() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            store.choosePicture(from: url)
            pictureChanged()
        }
    }

    private func pictureChanged() {
        if isOn { steam?.applyStreamerMode() }
    }
}

/// The picture as Steam's pages will show it: the stored image, or the
/// monogram drawn with the page's letters and color.
private struct StreamerPicturePreview: View {
    let name: String
    let picture: NSImage?

    /// The preview's edge in points.
    private static let edge: CGFloat = 32

    var body: some View {
        Group {
            if let picture {
                Image(nsImage: picture).resizable().scaledToFill()
            } else {
                ZStack {
                    Monogram.swiftUIColor(of: name)
                    Text(verbatim: Monogram.letters(of: name))
                        .font(.system(size: Self.edge * 0.44, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: Self.edge, height: Self.edge)
        .clipShape(RoundedRectangle(cornerRadius: 4))
    }
}

extension Monogram {
    /// ``color(of:)`` for SwiftUI: the same HSL color, restated as HSB.
    static func swiftUIColor(of name: String) -> Color {
        let saturation = Double(Self.saturation) / 100, lightness = Double(Self.lightness) / 100
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return Color(hue: Double(hue(of: name)) / 360, saturation: hsbSaturation, brightness: brightness)
    }
}
