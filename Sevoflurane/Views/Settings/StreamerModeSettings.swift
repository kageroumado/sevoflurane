import AppKit
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
        SettingsSection(title: "Streamer Mode") {
            SettingsToggle(
                title: "Streamer Mode",
                caption: String(localized: "Hides your name, picture, wallet, and friends in Steam\u{2019}s windows."),
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
            SettingsField(
                title: "Display name", prompt: StreamerMode.defaultDisplayName, text: $store.name,
                onSubmit: commitName,
            )
            .onChange(of: store.name) { store.storeName() }
            SettingsAction(
                title: "Avatar",
                caption: store.hasPicture
                    ? String(localized: "Shown in place of your Steam avatar.")
                    : String(localized: "A monogram of the display name."),
                state: .failure(ifPresent: store.pictureFailure),
            ) {
                SettingsThumbnail(
                    image: store.picture,
                    letters: Monogram.letters(of: StreamerMode.resolvedName(store.name)),
                    color: Monogram.swiftUIColor(of: StreamerMode.resolvedName(store.name)),
                )
                if store.hasPicture {
                    Button("Use Monogram") {
                        store.removePicture()
                        pictureChanged()
                    }
                }
                Button("Choose…") { choosePicture() }
            }
        }
        .onAppear { store.load() }
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

extension Monogram {
    /// ``color(of:)`` for SwiftUI: the same HSL color, restated as HSB.
    static func swiftUIColor(of name: String) -> Color {
        let saturation = Double(Self.saturation) / 100, lightness = Double(Self.lightness) / 100
        let brightness = lightness + saturation * min(lightness, 1 - lightness)
        let hsbSaturation = brightness == 0 ? 0 : 2 * (1 - lightness / brightness)
        return Color(hue: Double(hue(of: name)) / 360, saturation: hsbSaturation, brightness: brightness)
    }
}
