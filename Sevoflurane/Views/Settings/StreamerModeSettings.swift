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
            ToggleRow(
                title: "Streamer Mode",
                caption: String(localized: "Hides your name, picture, wallet and friends in Steam\u{2019}s windows."),
                help: .streamerMode,
                isOn: Binding(
                    get: { isOn },
                    set: { enabled in
                        StreamerMode.isOn = enabled
                        steam?.applyStreamerMode()
                    },
                ),
            )
            .highlightable(.generalStreamerMode, highlighted: highlighted)
            SettingsRow {
                TextField("Display name", text: $store.name, prompt: Text(verbatim: StreamerMode.defaultDisplayName))
                    .onSubmit(commitName)
                    .onChange(of: store.name) { store.storeName() }
            }
            pictureRow
        }
        .onAppear { store.load() }
    }

    private var pictureRow: some View {
        ActionRow(
            title: "Avatar",
            caption: store.pictureFailure ?? (store.hasPicture
                ? String(localized: "Shown in place of your Steam avatar.")
                : String(localized: "A monogram of the display name.")),
            isWarning: store.pictureFailure != nil,
        ) {
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
    private static let edge: CGFloat = 24

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
