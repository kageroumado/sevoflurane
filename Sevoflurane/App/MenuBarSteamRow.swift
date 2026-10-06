import AppKit
import Propofol
import SwiftUI

// MARK: - Steam

/// Metrics the Steam row and the renderer switch share, so the two zones
/// under the games stand the same height.
private enum ZoneMetrics {
    static let controlHeight: CGFloat = 30
}

/// The client in one row of glass: the way to its window, the friends list,
/// and how it is. The last two rest as icons and say their word on hover, so
/// Open Steam, the row's one accent, keeps most of it.
struct SteamRow: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                OpenSteamButton(host: host, supervisor: supervisor)
                FriendsButton(host: host)
                StatusChip(host: host, supervisor: supervisor)
            }
        }
    }
}

/// A glass capsule holding a symbol, and a word beside it while the pointer
/// is over it.
private struct HoverLabel: View {
    let symbol: String
    let word: LocalizedStringResource
    /// Shown whatever the hover: a count that is news.
    var badge: String?
    let isHovered: Bool

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .contentTransition(.symbolEffect(.replace))
                .accessibilityHidden(true)
            if isHovered {
                Text(word)
                    .font(.system(size: 11))
                    .fixedSize()
                    .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
            }
            if let badge {
                Text(badge)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
            }
        }
        .padding(.horizontal, isHovered || badge != nil ? Theme.Space.sm + 2 : 0)
        .frame(minWidth: ZoneMetrics.controlHeight, minHeight: ZoneMetrics.controlHeight)
    }
}

/// The client's status atom. Its state is in the symbol's shape, never its
/// color alone: a green dot and a red one are the same dot to a colorblind
/// eye. Never give it a control: a status light that also toggles gets
/// pressed as a light — the playtest's two unexplained pauses were exactly
/// that. The auto-restart switch is in Settings › General.
private struct StatusChip: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @State private var isHovered = false

    /// Every word that reports the client's run state names Steam, because the symbol alone says
    /// only how and nothing beside it says what about. The ones that skip the name report
    /// something else: the Steam account (signed out, or signed in elsewhere), this app's own switch, and the restart it is in the
    /// middle of.
    private var status: (word: LocalizedStringResource, symbol: String) {
        switch supervisor.health {
        case .starting, .launching: ("Steam starting", "hourglass")
        case .healthy where supervisor.session?.loss != nil:
            ("Signed in elsewhere", "person.crop.circle.badge.exclamationmark")
        case .healthy: ("Steam running", "checkmark.circle")
        case .waitingForSignIn: ("Signed out", "person.crop.circle.badge.questionmark")
        case .degraded: ("Steam wedged", "exclamationmark.triangle")
        case .restarting: ("Restarting", "arrow.triangle.2.circlepath")
        case .gaveUp: ("Steam stopped", "xmark.octagon")
        case .paused: ("Auto-restart off", "pause.circle")
        }
    }

    private var tooltip: String {
        var lines = ["\(supervisor.statusText) · \(host.status)"]
        if let event = EventLog.shared.latest {
            let time = event.date.formatted(date: .omitted, time: .shortened)
            lines.append(String(localized: "last event \(time) · \(event.message)"))
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        HoverLabel(symbol: status.symbol, word: status.word, isHovered: isHovered)
            .foregroundStyle(.secondary)
            .glassEffect(.regular, in: Capsule())
            .onHover { hovering in
                withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isHovered = hovering }
            }
            .help(tooltip)
            // Text to VoiceOver, where the glass would make it an unknown
            // element: this reports, it does not act.
            .accessibilityRepresentation {
                Text(status.word)
            }
    }
}

/// The friends list, with the number of waiting conversations beside the
/// icon while there are any. The count is conversations, not messages — the
/// number Steam posts to the client for its own tray badge, and a
/// conversation is what a click opens. It opens the list, or the oldest
/// waiting conversation, as its own window; Steam's desktop window is never
/// involved.
private struct FriendsButton: View {
    let host: SteamWebHost
    @State private var isHovered = false

    var body: some View {
        let unreadChats = host.unreadChats
        Button { host.openFriends() } label: {
            HoverLabel(
                symbol: "person.2.fill", word: "Friends",
                badge: unreadChats > 0 ? "\(unreadChats)" : nil,
                isHovered: isHovered,
            )
            .foregroundStyle(unreadChats > 0 ? AnyShapeStyle(Theme.onAccent) : AnyShapeStyle(.secondary))
            .contentShape(Capsule())
            .glassEffect(
                unreadChats > 0 ? .regular.tint(.accentColor).interactive() : .regular.interactive(),
                in: Capsule(),
            )
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isHovered = hovering }
        }
        .keyboardShortcut("f")
        .accessibilityLabel(MenuBarView.friendsLabel(unreadChats: unreadChats))
        .help(MenuBarView.friendsLabel(unreadChats: unreadChats))
    }
}

private struct OpenSteamButton: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        let canOpenSteam = supervisor.health.canOpenSteam
        Button { host.showSteam() } label: {
            Label("Open Steam", systemImage: "macwindow")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.onAccent)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: ZoneMetrics.controlHeight)
                .contentShape(Capsule())
                .glassEffect(.regular.tint(.accentColor).interactive(), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .keyboardShortcut("o")
        .disabled(!canOpenSteam)
        .opacity(canOpenSteam ? 1 : 0.5)
        .help(host.isSteamOnScreen ? "Bring Steam's window to the front" : "Steam's window is hidden")
    }
}

// MARK: - Bottle completeness

/// The one line the popover says about an unfinished bottle: that required
/// components are missing, and where to install them. Games still launch —
/// this is a note, not a gate — so it stays a chip rather than a card, and it
/// is absent on a complete bottle.
struct BottleIncompleteChip: View {
    let summary: String?

    var body: some View {
        if let summary {
            Button {
                NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
            } label: {
                Label("Bottle incomplete", systemImage: "shippingbox")
                    .foregroundStyle(.orange)
            }
            .buttonStyle(.plain)
            .help("\(summary). Install them in Settings › Engine › Game dependencies.")
        }
    }

    @concurrent
    nonisolated static func read() async -> String? {
        BottleReadiness.incompleteSummary()
    }
}

private extension SupervisorHealth {
    /// Whether a click on Open Steam would actually put Steam on screen.
    /// While the client is coming up, restarting, or crash-looped, the
    /// health card above already says what's happening — an enabled button
    /// under it would promise a window that can't appear.
    var canOpenSteam: Bool {
        switch self {
        case .starting, .launching, .restarting, .gaveUp: false
        case .healthy, .waitingForSignIn, .degraded, .paused: true
        }
    }
}
