import AppKit
import Propofol
import SwiftUI

/// The menu-bar extra: what Steam's own tray menu shows — recent games first,
/// then the client controls.
///
/// The design is Propofol, the suite's shared popover language (adrafinil,
/// phosphene, dantrolene, rocuronium): one radius/spacing ladder, one popover
/// width, the same header and footer chips. Reinterpreted for Steam: the
/// library leads, the supervisor speaks only when something needs attention,
/// and every footer control that isn't a universal glyph says what it does.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            PopoverHeader("Sevoflurane")
            healthCard
            recentGames
            openSteamButton
            FooterBar(host: host, supervisor: supervisor)
        }
        // Tighter than Propofol's outer `lg`: this popover's rows carry their
        // own inset, and at `lg` the two stack into a wide empty gutter.
        .padding(Theme.Space.md)
        .frame(width: Theme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        .animation(.smooth(duration: 0.3), value: supervisor.health)
        .animation(.smooth(duration: 0.3), value: host.recentGames)
        .animation(.smooth(duration: 0.3), value: host.activeLaunch)
        .onAppear {
            host.refreshRecentGames()
            SilentUpdates.shared.refresh()
        }
    }

    // MARK: - Health card

    /// What the supervisor card shows for the current health state, or `nil`
    /// when the client is healthy and the card stays out of the way.
    private struct HealthCard {
        let symbol: String
        let title: String
        let detail: String
        /// Severity color for the symbol. The card's glass stays neutral in
        /// every state: a card that turns red carries the alarm twice, and the
        /// popover is where the user comes to *fix* it.
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
        case let .launching(phase):
            HealthCard(
                symbol: "hourglass",
                title: "Starting Steam",
                detail: phase + " — the first launch takes a minute.",
                tint: nil,
                action: nil,
            )
        case .waitingForSignIn:
            HealthCard(
                symbol: "person.crop.circle",
                title: "Waiting for sign-in",
                detail: "Sign in to Steam in the login window to finish setting up.",
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
            HStack(spacing: Theme.Space.md) {
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
                    Button(action.label, action: action.run)
                        .buttonStyle(.glassProminent)
                        .controlSize(.small)
                        .foregroundStyle(Theme.onAccent)
                }
            }
            .padding(Theme.Space.md)
            .glassCard()
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private var isRestarting: Bool {
        if case .restarting = supervisor.health { true } else { false }
    }

    // MARK: - Recent games

    /// No heading: five pieces of box art under the app's own name need no
    /// label to say they are games.
    @ViewBuilder private var recentGames: some View {
        if host.recentGames.isEmpty {
            // A popover with nothing between the header and the button reads
            // as a failure; a library with no installed games is not one.
            Text("No games installed yet.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Theme.Space.sm)
        } else {
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
                HStack(spacing: Theme.Space.md) {
                    capsuleArt
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
                    Spacer(minLength: Theme.Space.sm)
                    // The row is flush with the popover's own padding, so the
                    // play badge needs its own inset or it rides the edge.
                    trailing.padding(.trailing, Theme.Space.lg)
                }
                // No horizontal inset: the art, the Open Steam button and the
                // footer chips all start at the popover's own padding, so the
                // column reads as one edge rather than the rows sitting in
                // from everything else.
                .padding(.vertical, Theme.Space.xs)
                .contentShape(Theme.innerShape)
            }
            .buttonStyle(PressableStyle())
            .background(
                Theme.innerShape.fill(Color.primary.opacity(isHovered ? 0.07 : 0)),
            )
            .onHover { hovering in
                withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
            }
        }

        private var capsuleArt: some View {
            AsyncImage(url: game.artURL) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary.opacity(0.5))
            }
            .frame(width: 27, height: 40)
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        }

        /// The launch affordance: a filled accent disc big enough to read as
        /// the row's button, in place of the small tinted glyph a pointer had
        /// to hunt for. It appears on hover, where the spinner replaces it for
        /// the length of a launch.
        @ViewBuilder private var trailing: some View {
            if isLaunching || launchDetail != nil {
                ProgressView()
                    .controlSize(.small)
                    .scaleEffect(0.8)
                    .frame(width: 26, height: 26)
            } else {
                Image(systemName: "play.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Theme.onAccent)
                    .frame(width: 26, height: 26)
                    .background(Color.accentColor, in: Circle())
                    .opacity(isHovered ? 1 : 0)
                    .scaleEffect(isHovered ? 1 : 0.7)
            }
        }
    }

    // MARK: - Primary action

    private var openSteamButton: some View {
        Button { host.showSteam() } label: {
            Text("Open Steam")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.onAccent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, Theme.Space.sm)
                .contentShape(Capsule())
        }
        .buttonStyle(ProminentFillStyle())
        .keyboardShortcut("o")
    }
}
