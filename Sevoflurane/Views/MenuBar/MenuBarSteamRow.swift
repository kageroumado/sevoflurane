import AppKit
import Propofol
import SwiftUI

// MARK: - Steam

/// Shared by the Steam row and the renderer switch so they match in height.
private enum ZoneMetrics {
    static let controlHeight: CGFloat = 30
}

/// Open Steam, then the friends list, Discord and status as icons that show
/// their word on hover.
struct SteamRow: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        GlassEffectContainer(spacing: 0) {
            HStack(spacing: Theme.Space.xs) {
                OpenSteamButton(host: host, supervisor: supervisor)
                FriendsButton(host: host)
                DiscordButton()
                StatusChip(host: host, supervisor: supervisor)
            }
        }
    }
}

/// A glass capsule holding a symbol, with its word while hovered.
private struct HoverLabel: View {
    /// An SF Symbol by name, or an asset drawn as a template at symbol size.
    enum Glyph {
        case symbol(String)
        case asset(String)
    }

    let glyph: Glyph
    let word: LocalizedStringResource
    /// Shown whatever the hover: a count that is news.
    var badge: String?
    let isHovered: Bool

    init(symbol: String, word: LocalizedStringResource, badge: String? = nil, isHovered: Bool) {
        self.init(glyph: .symbol(symbol), word: word, badge: badge, isHovered: isHovered)
    }

    init(glyph: Glyph, word: LocalizedStringResource, badge: String? = nil, isHovered: Bool) {
        self.glyph = glyph
        self.word = word
        self.badge = badge
        self.isHovered = isHovered
    }

    var body: some View {
        HStack(spacing: 5) {
            switch glyph {
            case let .symbol(symbol):
                Image(systemName: symbol)
                    .font(.system(size: 12))
                    .contentTransition(.symbolEffect(.replace))
                    .accessibilityHidden(true)
            case let .asset(name):
                Image(name)
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 13, height: 13)
                    .accessibilityHidden(true)
            }
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

/// The client's status, told by the symbol's shape for colorblind eyes.
/// Never give it a control: a status light that toggles gets pressed by
/// accident and pauses the client.
private struct StatusChip: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @State private var isHovered = false

    /// Words about the client's run state name Steam; the symbol alone does not.
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
            // Plain text to VoiceOver; the glass would read as an unknown element.
            .accessibilityRepresentation {
                Text(status.word)
            }
    }
}

/// The friends list, badged with waiting conversations (Steam's own tray
/// count). A click opens the list or the oldest waiting chat in its own window.
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

/// The app's Discord server. The mark is the Simple Icons tracing (CC0),
/// drawn as a template.
private struct DiscordButton: View {
    static let inviteURL = URL(string: "https://discord.gg/BJYJvZGqHX")!
    @State private var isHovered = false

    var body: some View {
        Button { NSWorkspace.shared.open(Self.inviteURL) } label: {
            HoverLabel(glyph: .asset("DiscordMark"), word: "Discord", isHovered: isHovered)
                .foregroundStyle(.secondary)
                .contentShape(Capsule())
                .glassEffect(.regular.interactive(), in: Capsule())
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.spring(response: 0.3, dampingFraction: 0.85)) { isHovered = hovering }
        }
        .accessibilityLabel(String(localized: "Join the Sevoflurane Discord"))
        .help("Join the Sevoflurane Discord server")
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

/// Says required components are missing and where to install them; absent
/// on a complete bottle.
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
    /// Whether a click on Open Steam would put Steam on screen.
    var canOpenSteam: Bool {
        switch self {
        case .starting, .launching, .restarting, .gaveUp: false
        case .healthy, .waitingForSignIn, .degraded, .paused: true
        }
    }
}
