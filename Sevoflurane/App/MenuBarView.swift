import AppKit
import SwiftUI

/// The menu-bar extra: what Steam's own tray menu shows — recent games first,
/// then the client controls.
///
/// The design follows the kagerou house language (adrafinil, phosphene):
/// one accent hue, low-opacity semantic fills instead of borders, capsule
/// chips, uppercase kerned section labels, hover as a first-class state.
/// Reinterpreted for Steam: the library leads, and the supervisor speaks
/// only when something needs attention.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            healthCard
            recentGames
            openSteamButton
            footer
        }
        .padding(14)
        .frame(width: 320)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: supervisor.health)
        .animation(.smooth(duration: 0.3), value: host.recentGames)
        .animation(.smooth(duration: 0.3), value: host.activeLaunch)
        .onAppear { host.refreshRecentGames() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Sevoflurane")
                .font(.system(size: 15, weight: .bold))
            Spacer()
            Button {
                openURL(URL(string: "https://kagerou.glass")!)
            } label: {
                Text("made by kageroumado \(Image(systemName: "arrow.up.right"))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
    }

    // MARK: - Health card

    /// What the supervisor card shows for the current health state, or `nil`
    /// when the client is healthy and the card stays out of the way.
    private struct HealthCard {
        let symbol: String
        let title: String
        let detail: String
        /// Severity tint for the icon and the card fill; `nil` reads neutral.
        let tint: Color?
        let action: (label: String, run: () -> Void)?
    }

    private var healthCardModel: HealthCard? {
        switch supervisor.health {
        case .healthy:
            nil
        case .starting:
            HealthCard(
                symbol: "hourglass",
                title: "Starting up",
                detail: supervisor.statusText,
                tint: nil,
                action: nil,
            )
        case .degraded:
            HealthCard(
                symbol: "exclamationmark.triangle.fill",
                title: "Steam is struggling",
                detail: supervisor.statusText,
                tint: .orange,
                action: nil,
            )
        case .restarting:
            HealthCard(
                symbol: "arrow.triangle.2.circlepath",
                title: "Restarting Steam",
                detail: supervisor.statusText,
                tint: .accentColor,
                action: nil,
            )
        case .gaveUp:
            HealthCard(
                symbol: "exclamationmark.octagon.fill",
                title: "Steam needs a hand",
                detail: supervisor.statusText,
                tint: .red,
                action: ("Restart Now", { supervisor.restartNow() }),
            )
        case .paused:
            HealthCard(
                symbol: "moon.zzz",
                title: "Auto-restart paused",
                detail: "Sevoflurane won't revive a hung client.",
                tint: nil,
                action: ("Resume", { supervisor.togglePaused() }),
            )
        }
    }

    @ViewBuilder private var healthCard: some View {
        if let card = healthCardModel {
            HStack(spacing: 10) {
                Image(systemName: card.symbol)
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(card.tint ?? Color.secondary)
                    .symbolEffect(
                        .rotate,
                        options: .repeat(.continuous),
                        isActive: isRestarting,
                    )
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(card.title)
                        .font(.system(size: 12, weight: .semibold))
                    Text(card.detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                if let action = card.action {
                    ChipButton(
                        title: action.label,
                        prominent: true,
                        action: action.run,
                    )
                }
            }
            .padding(12)
            .background(
                card.tint.map { AnyShapeStyle($0.opacity(0.14)) }
                    ?? AnyShapeStyle(.quinary),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous),
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var isRestarting: Bool {
        if case .restarting = supervisor.health { true } else { false }
    }

    // MARK: - Recent games

    @ViewBuilder private var recentGames: some View {
        if !host.recentGames.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Text("Recent Games")
                    .font(.system(size: 10.5, weight: .semibold))
                    .kerning(0.7)
                    .textCase(.uppercase)
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 4)
                VStack(spacing: 1) {
                    ForEach(host.recentGames) { game in
                        GameRow(
                            game: game,
                            launchDetail: host.activeLaunch
                                .flatMap { $0.appID == game.id ? $0.detail : nil },
                        ) {
                            host.launchGame(game)
                        }
                    }
                }
            }
        }
    }

    private struct GameRow: View {
        let game: SteamWebHost.RecentGame
        /// What the client says it is doing right now for this app
        /// (game-action events); `nil` outside a launch.
        let launchDetail: String?
        let launch: () -> Void
        @State private var isHovered = false
        /// Instant acknowledgment for the click; the client's first
        /// game-action event takes over from it, and it stands alone as an
        /// 8s fallback if no events arrive.
        @State private var isLaunching = false

        var body: some View {
            Button {
                guard !isLaunching else { return }
                launch()
                withAnimation(.easeInOut(duration: 0.15)) { isLaunching = true }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    withAnimation(.easeInOut(duration: 0.3)) { isLaunching = false }
                }
            } label: {
                HStack(spacing: 8) {
                    AsyncImage(url: game.artURL) { image in
                        image.resizable().aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Rectangle().fill(.quaternary.opacity(0.5))
                    }
                    .frame(width: 27, height: 40)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(game.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        if let launchDetail {
                            Text(launchDetail)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .transition(.opacity)
                        }
                    }
                    Spacer(minLength: 0)
                    if isLaunching || launchDetail != nil {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                            .frame(width: 12, height: 12)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentColor)
                            .opacity(isHovered ? 1 : 0)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 5)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            .buttonStyle(PressableStyle())
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(isHovered ? 0.07 : 0)),
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        }
    }

    // MARK: - Primary action

    private var openSteamButton: some View {
        Button { host.showSteam() } label: {
            Text("Open Steam")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Ink.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(ProminentFillStyle())
        .keyboardShortcut("o")
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 5) {
            StatusChip(host: host, supervisor: supervisor)
            ChipButton(title: "Log", systemImage: "doc.text") {
                NSWorkspace.shared.open(EventLog.fileURL)
            }
            .help("Open the event log")
            Spacer(minLength: 0)
            RoundSettingsLink()
            RoundIconButton(
                symbol: "arrow.clockwise",
                label: "Reload Steam UI",
                help: "Reload Steam's UI without touching the client",
            ) {
                host.reload()
            }
            RoundIconButton(
                symbol: "arrow.triangle.2.circlepath",
                label: "Restart Steam client",
                help: "Restart the Windows Steam client in its bottle",
            ) {
                supervisor.restartNow()
            }
            RoundIconButton(
                symbol: "xmark",
                label: "Quit",
                help: "Quit Sevoflurane and shut down the Steam client",
                shortcut: "q",
            ) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    /// The footer's status atom: a health dot and one word at rest; on hover
    /// it flips into the auto-restart switch, so the setting costs no space.
    private struct StatusChip: View {
        let host: SteamWebHost
        let supervisor: ClientSupervisor
        @State private var isHovered = false

        private var status: (word: String, color: Color) {
            switch supervisor.health {
            case .starting: ("Starting", .gray)
            case .healthy: ("Healthy", .green)
            case .degraded: ("Degraded", .orange)
            case .restarting: ("Restarting", .accentColor)
            case .gaveUp: ("Stopped", .red)
            case .paused: ("Paused", .gray)
            }
        }

        private var tooltip: String {
            var lines = ["\(supervisor.statusText) · \(host.status)"]
            if let event = EventLog.shared.latest {
                let time = event.date.formatted(date: .omitted, time: .shortened)
                lines.append("last event \(time) — \(event.message)")
            }
            lines.append("Click to pause or resume auto-restart.")
            return lines.joined(separator: "\n")
        }

        var body: some View {
            Button { supervisor.togglePaused() } label: {
                HStack(spacing: 4) {
                    if isHovered {
                        SwitchPip(isOn: supervisor.health != .paused)
                        Text("Auto-restart")
                    } else {
                        Circle()
                            .fill(status.color)
                            .frame(width: 7, height: 7)
                        Text(status.word)
                    }
                }
                .frame(height: 12)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background(
                    isHovered ? AnyShapeStyle(.quaternary) : AnyShapeStyle(.quinary),
                    in: Capsule(),
                )
                .contentShape(Capsule())
            }
            .buttonStyle(PressableStyle())
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
            .help(tooltip)
        }
    }

    private struct SwitchPip: View {
        let isOn: Bool

        var body: some View {
            Capsule()
                .fill(isOn ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                .frame(width: 20, height: 12)
                .overlay(alignment: isOn ? .trailing : .leading) {
                    Circle()
                        .fill(.white)
                        .frame(width: 8, height: 8)
                        .padding(2)
                }
                .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isOn)
        }
    }
}
