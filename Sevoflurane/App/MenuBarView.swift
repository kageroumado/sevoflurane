import AppKit
import Propofol
import SwiftUI
import UserNotifications

/// The menu-bar extra: what Steam's own tray menu shows — recent games first,
/// then the client controls.
///
/// The design is Propofol, the popover language the maintainer's menu-bar
/// apps share (Adrafinil, Phosphene, Dantrolene): one radius/spacing ladder, one popover
/// width, the same header and footer chips. Reinterpreted for Steam: the
/// library leads, the supervisor speaks only when something needs attention,
/// and every footer control that isn't a universal glyph says what it does.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let notifications: SteamNotifications

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            PopoverHeader("Sevoflurane")
            steamWindowRow
            healthCard
            BottleIncompleteChip()
            recentGames
            stagedRendererCaption
            friendsRow
            notificationPermissionCard
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
        .animation(.smooth(duration: 0.3), value: host.unreadChats)
        .animation(.smooth(duration: 0.3), value: notifications.hasUnaskedNotifications)
        .onAppear {
            host.refreshRecentGames()
            SilentUpdates.shared.refresh()
        }
    }

    // MARK: - Where Steam's window is

    /// A running client with no window on screen looks exactly like a client
    /// that failed to start, and the only thing on screen saying otherwise is
    /// an 18-point menu-bar glyph. So the popover says which it is, next to
    /// the one click that fixes it.
    @ViewBuilder private var steamWindowRow: some View {
        if canOpenSteam, !host.isSteamOnScreen {
            HStack(spacing: Theme.Space.xs) {
                Image(systemName: "macwindow")
                Text("Steam window: hidden")
                Spacer()
                Button("Show") { host.showSteam() }
                    .buttonStyle(.link)
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
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
        /// A second, quieter button beside the first — the state where the
        /// user has somewhere to go *and* something to try again.
        var alternative: (label: String, run: () -> Void)?
    }

    /// Supervision runs in a background helper macOS asks the user to approve,
    /// so "it is not approved" is a state of its own with a way out, not a
    /// Steam fault to restart out of.
    private var daemonCard: HealthCard {
        HealthCard(
            symbol: "gearshape.badge.exclamationmark",
            title: "Sevoflurane needs its background helper",
            detail: supervisor.statusText,
            tint: .red,
            action: ("Open Login Items", { DaemonService.openLoginItems() }),
            alternative: ("Retry", {
                Task(name: "Retry the daemon") { await supervisor.attach() }
            }),
        )
    }

    private var healthCardModel: HealthCard? {
        if supervisor.daemonIsUnreachable { return daemonCard }
        return switch supervisor.health {
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
            // The phase says which startup this is; the card must not, because
            // it draws for a session's first launch and for the wait after a
            // restart alike.
            HealthCard(
                symbol: "hourglass",
                title: "Starting Steam",
                detail: phase,
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
                if let alternative = card.alternative {
                    Button(alternative.label, action: alternative.run)
                        .buttonStyle(.glass)
                        .controlSize(.small)
                }
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
    /// What a game will actually load — the renderer the running client is
    /// staged for, read back from the booted record, not the pending pick.
    @ViewBuilder private var stagedRendererCaption: some View {
        if !host.recentGames.isEmpty, let booted = BottleGraphics.bootedSelection() {
            let version = booted.renderer == .d3dmetal
                ? (booted.d3dMetalVersion.map { " \($0)" } ?? "")
                : ""
            Label(
                "Games run on \(booted.renderer.label)\(version)",
                systemImage: "cube.transparent",
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .padding(.horizontal, Theme.Space.xs)
        }
    }

    /// The press is the app's claim to the activation right, and the game's
    /// window is what it will be spent on a minute later. The popover itself
    /// is a non-activating panel — it must stay one, or every click in it
    /// would pull focus off whatever the user was doing — so the press says
    /// so explicitly instead.
    private func claimActivationRight() {
        Activation().claimRight()
    }

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
                        pinned: BottleGraphics.overrides()[game.id]?.renderer,
                        setPin: { renderer in
                            BottleGraphics.setOverride(
                                renderer.map {
                                    BottleGraphics.Override(renderer: $0, name: game.name)
                                },
                                forApp: game.id,
                                named: game.name,
                            )
                        },
                        launch: {
                            claimActivationRight()
                            Task(name: "Launch \(game.name)") { await supervisor.launch(game) }
                        },
                        runWith: { renderer in
                            claimActivationRight()
                            Task(name: "Run \(game.name) on \(renderer.label)") {
                                await supervisor.launch(game, renderer: renderer)
                            }
                        },
                    )
                }
            }
        }
    }

    private struct GameRow: View {
        let game: SteamWebHost.RecentGame
        /// What the client says it is doing right now for this app
        /// (game-action events); `nil` outside a launch.
        let launchDetail: String?
        /// The renderer this game is pinned to, if any.
        let pinned: Renderer?
        let setPin: (Renderer?) -> Void
        let launch: () -> Void
        /// Swap to this renderer and launch immediately (context menu).
        let runWith: (Renderer) -> Void
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
                        } else if let restartFor {
                            // Pinned to a renderer the running client did not
                            // boot with: the launch path restages it (or
                            // restarts, if the engine or sync must change).
                            // Better said before the click than after.
                            Text("\(restartFor.label) — set when it launches")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
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
            .contextMenu {
                // One-shot: swap the renderer and launch now. The launch path
                // restages the tree (or restarts, if the engine or sync must
                // change) before the game starts.
                Menu("Run with…") {
                    ForEach(Renderer.allCases.filter { $0 != .auto }, id: \.self) { renderer in
                        Button(renderer.label) { runWith(renderer) }
                    }
                }
                Divider()
                Picker("Always run with", selection: pinBinding) {
                    Text("Bottle default").tag(Renderer?.none)
                    ForEach(Renderer.allCases.filter { $0 != .auto }, id: \.self) { renderer in
                        Text(renderer.label).tag(Renderer?.some(renderer))
                    }
                }
            }
        }

        /// What the pin menu reads and writes.
        private var pinBinding: Binding<Renderer?> {
            Binding(get: { pinned }, set: { setPin($0) })
        }

        /// The renderer this launch would have to restart the client for.
        private var restartFor: Renderer? {
            BottleGraphics.rendererNeedingRestart(forApp: game.id)
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

    // MARK: - Friends

    /// The other half of what a menu-bar Steam is for. It says what is
    /// waiting rather than a bare "Friends", and clicking it opens the
    /// friends list — or, with messages waiting, the oldest of them — as its
    /// own window. Steam's desktop window is never involved.
    private var friendsRow: some View {
        FriendsRow(unreadChats: host.unreadChats) { host.openFriends() }
    }

    /// Built like a game row so the two read as one column: the same leading
    /// inset, the same hover fill, the same vertical rhythm.
    private struct FriendsRow: View {
        let unreadChats: Int
        let open: () -> Void
        @State private var isHovered = false

        var body: some View {
            Button(action: open) {
                HStack(spacing: Theme.Space.md) {
                    Image(systemName: "person.2.fill")
                        .font(.system(size: 13))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(unreadChats > 0 ? Color.accentColor : Color.secondary)
                        .frame(width: 27)
                    // The count is in the words. A badge beside them would
                    // say the same number twice, which is the one thing this
                    // popover's rows never do.
                    Text(MenuBarView.friendsLabel(unreadChats: unreadChats))
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    Spacer(minLength: Theme.Space.sm)
                }
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
            .keyboardShortcut("f")
        }
    }

    /// "Friends", or what is waiting in it. The count is conversations, not
    /// messages — it is the number Steam itself posts to the client for its
    /// own tray badge, and a conversation is what a click opens.
    static func friendsLabel(unreadChats: Int) -> String {
        switch unreadChats {
        case 0: "Friends"
        case 1: "Friends · 1 new message"
        default: "Friends · \(unreadChats) new messages"
        }
    }

    // MARK: - Notification permission

    /// Where the app asks to post notifications.
    ///
    /// An app with no window on first run has nowhere honest to raise the
    /// system alert at launch, and asking before there is anything to show
    /// asks for a permission the user has no reason to weigh yet. So nothing
    /// is asked until Steam actually produces a notification: the first one
    /// is held, the menu-bar dot goes up for it, and this row is what the
    /// user finds when they open the popover to see why. The prompt is then
    /// raised by their click on it.
    @ViewBuilder private var notificationPermissionCard: some View {
        if notifications.hasUnaskedNotifications || notifications.authorization == .denied {
            let denied = notifications.authorization == .denied
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "bell.badge")
                    .font(.system(size: 18))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(denied ? "Notifications are off" : "Steam has something to tell you")
                        .font(.system(size: 12, weight: .semibold))
                    Text(
                        denied
                            ? "Turn Sevoflurane back on in System Settings to get messages here."
                            : "Let Sevoflurane post Steam's messages to Notification Center.",
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Button(denied ? "Open Settings" : "Turn On") {
                    if denied {
                        notifications.openSystemSettings()
                    } else {
                        Task(name: "Ask for notification permission") {
                            await notifications.requestAuthorization()
                        }
                    }
                }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
                .foregroundStyle(Theme.onAccent)
            }
            .padding(Theme.Space.md)
            .glassCard()
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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
        .disabled(!canOpenSteam)
        .opacity(canOpenSteam ? 1 : 0.5)
    }

    /// Whether a click on Open Steam would actually put Steam on screen.
    /// While the client is coming up, restarting, or crash-looped, the
    /// health card above already says what's happening — an enabled button
    /// under it would promise a window that can't appear.
    private var canOpenSteam: Bool {
        switch supervisor.health {
        case .starting, .launching, .restarting, .gaveUp: false
        case .healthy, .waitingForSignIn, .degraded, .paused: true
        }
    }
}

// MARK: - Bottle completeness

/// The one line the popover says about an unfinished bottle: that required
/// components are missing, and where to install them. Games still launch —
/// this is a note, not a gate — so it stays a chip rather than a card, and it
/// is absent on a complete bottle.
private struct BottleIncompleteChip: View {
    /// Read once per appearance: the test opens files inside the prefix,
    /// which is not something a view body may do.
    @State private var summary: String?

    var body: some View {
        Group {
            if let summary {
                Button {
                    NSApp.sendAction(#selector(AppDelegate.showSettings(_:)), to: nil, from: nil)
                } label: {
                    Label("Bottle incomplete", systemImage: "shippingbox")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
                .help("\(summary). Install them in Settings › Engine › Game dependencies.")
                .padding(.horizontal, Theme.Space.xs)
            }
        }
        .onAppear { summary = BottleReadiness.incompleteSummary() }
    }
}
