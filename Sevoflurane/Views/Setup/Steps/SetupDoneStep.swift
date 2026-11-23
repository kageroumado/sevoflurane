import Propofol
import SwiftUI

/// The last screen. Its title, sentence and button follow what Steam is
/// doing behind it: ready, starting, or unable to start, with the one thing
/// that helps.
struct SetupDoneStep: View {
    let store: SetupStore

    var body: some View {
        @Bindable var store = store
        let window = store.steamWindow
        let state = Standing(window: window, repair: store.helperRepair)
        // Steam on its way has nothing to press: the screen turns by itself.
        SetupScreenLayout(hasButtons: state != .starting) {
            SetupHero(title: state.title, caption: Text(state.caption)) {
                picture(for: state)
            } content: {
                VStack(spacing: Theme.Space.lg) {
                    if state == .helperDown, let repair = store.helperRepair, repair.isFailure {
                        SettingsStatus(.failure, repair.sentence)
                    }
                    // Where the app lives and whether it opens by itself
                    // matter once Steam is on its way, not while it cannot start.
                    if state == .ready || state == .signIn || state == .starting {
                        Text("Sevoflurane stays in the menu bar: \(Text(Image(nsImage: MenuBarIcon.image(badged: false))).baselineOffset(Self.glyphDrop))")
                        Toggle("Open Sevoflurane at login", isOn: $store.opensAtLogin)
                            .toggleStyle(.checkbox)
                    }
                }
            }
        } secondary: {
            if state == .signIn {
                Button("Not Now") { store.skipSignIn() }
                    .help("Run Windows programs from Quick Launch. You can sign in to Steam later from the menu bar.")
            }
        } primary: {
            switch state {
            case .ready, .signIn: Button("Open Steam") { store.finish() }
            case .starting: EmptyView()
            case .helperDown: Button("Fix It") { store.repairHelper() }.disabled(store.isRepairingHelper)
            case .helperNeedsApproval: Button("Open Login Items") { store.openLoginItems() }
            case .gaveUp: Button("Start Steam Again") { store.restartSteam() }
            }
        }
    }

    /// Sets the menu-bar glyph, taller than the text's capitals, on the line.
    private static let glyphDrop: CGFloat = -4
    private static let pictureSize: CGFloat = 88

    @ViewBuilder
    private func picture(for state: Standing) -> some View {
        switch state {
        case .ready, .signIn:
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: Self.pictureSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.green)
                .accessibilityHidden(true)
        case .starting:
            ProgressView()
                .controlSize(.extraLarge)
        case .helperDown, .helperNeedsApproval, .gaveUp:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Self.pictureSize))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
        }
    }

    /// What the screen says: Steam's windows, and for a helper that is
    /// down, whether macOS is waiting for an approval.
    private enum Standing {
        case ready
        case signIn
        case starting
        case helperDown
        case helperNeedsApproval
        case gaveUp

        init(window: SetupSteamWindow, repair: DaemonService.RepairResult?) {
            switch window {
            case .library: self = .ready
            case .signIn: self = .signIn
            case .starting: self = .starting
            case .gaveUp: self = .gaveUp
            case .helperDown:
                if case .needsApproval = repair { self = .helperNeedsApproval } else { self = .helperDown }
            }
        }

        var title: LocalizedStringResource {
            switch self {
            case .ready, .signIn: "Steam is ready"
            case .starting: "Steam is starting"
            case .helperDown, .helperNeedsApproval: "Steam cannot start yet"
            case .gaveUp: "Steam did not start"
            }
        }

        var caption: LocalizedStringResource {
            switch self {
            case .signIn: "Sign in to see your games."
            case .ready: "Your games are in its library."
            case .starting: "Its first start can take a minute."
            case .helperDown: "A part of Sevoflurane that starts Steam is not running."
            case .helperNeedsApproval: "Turn on Sevoflurane under \u{201C}Allow in the Background\u{201D}, then come back."
            case .gaveUp: "Steam closed right after starting."
            }
        }
    }
}
