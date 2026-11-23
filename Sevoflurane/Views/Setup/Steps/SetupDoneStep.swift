import Propofol
import SwiftUI

/// The last screen. Its title, sentence and button follow what Steam is
/// doing behind it: ready, starting, or unable to start, with the one thing
/// that helps.
struct SetupDoneStep: View {
    let store: SetupStore

    var body: some View {
        let window = store.steamWindow
        SetupScreenLayout {
            SetupHero(title: title(for: window), caption: caption(for: window)) {
                Image(systemName: isReady(window) ? "checkmark.circle.fill" : symbol(for: window))
                    .font(.system(size: 88))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(isReady(window) ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
                    .accessibilityHidden(true)
            } content: {
                VStack(spacing: Theme.Space.lg) {
                    if let repair = store.helperRepair, window == .helperDown {
                        SettingsStatus(repair.isFailure ? .failure : .done, repair.sentence)
                    }
                    // Where the app lives and whether it opens by itself
                    // matter once Steam is on its way, not while it cannot start.
                    if isReady(window) || window == .starting {
                        Text("Sevoflurane stays in the menu bar: \(Text(Image(nsImage: MenuBarIcon.image(badged: false))).baselineOffset(Self.glyphDrop))")
                        Toggle("Open Sevoflurane at login", isOn: Binding(
                            get: { store.opensAtLogin },
                            set: { store.setOpensAtLogin($0) },
                        ))
                        .toggleStyle(.checkbox)
                    }
                }
            }
        } secondary: {
            switch window {
            case .signIn:
                Button("Skip Sign-In") { store.skipSignIn() }
                    .help("Run Windows programs from Quick Launch. You can sign in to Steam later from the menu bar.")
            case .helperDown:
                Button("Open Login Items") { store.openLoginItems() }
            case .starting, .gaveUp, .library:
                EmptyView()
            }
        } primary: {
            switch window {
            case .signIn, .library:
                Button("Open Steam") { store.finish() }
            case .starting:
                Button("Open Steam") {}
                    .disabled(true)
            case .helperDown:
                Button("Repair Helper") { store.repairHelper() }
                    .disabled(store.isRepairingHelper)
            case .gaveUp:
                Button("Start Steam Again") { store.restartSteam() }
            }
        }
    }

    /// Sets the menu-bar glyph, taller than the text's capitals, on the line.
    private static let glyphDrop: CGFloat = -4

    private func isReady(_ window: SetupSteamWindow) -> Bool {
        window == .signIn || window == .library
    }

    private func symbol(for window: SetupSteamWindow) -> String {
        window == .starting ? "hourglass.circle.fill" : "exclamationmark.triangle.fill"
    }

    private func title(for window: SetupSteamWindow) -> LocalizedStringResource {
        switch window {
        case .signIn, .library: "Steam is ready"
        case .starting: "Steam is starting"
        case .helperDown: "Steam cannot start yet"
        case .gaveUp: "Steam did not start"
        }
    }

    private func caption(for window: SetupSteamWindow) -> Text {
        switch window {
        case .signIn: Text("Sign in to see your games.")
        case .library: Text("Your games are in its library.")
        case .starting: Text("Its first start can take a minute.")
        case .helperDown: Text("Sevoflurane\u{2019}s background helper starts Steam, and it is not running.")
        case let .gaveUp(reason): Text(SetupFailureText.asSentence(reason))
        }
    }
}
