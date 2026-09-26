import AppKit
import Propofol
import SwiftUI
import UserNotifications

/// The menu-bar extra, read top to bottom: what to play, the Steam client it
/// plays through, and the app's own bar with the renderer the games run on.
///
/// The design is Propofol, the popover language the maintainer's menu-bar
/// apps share (Adrafinil, Phosphene, Dantrolene): one radius/spacing ladder, one popover
/// width, the same header and footer chips. Reinterpreted for Steam: the
/// library leads, the supervisor speaks only when something needs attention,
/// and each zone says what it is by what it holds rather than by a heading.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let notifications: SteamNotifications
    let quickLaunch: QuickLaunchStore
    let graphics: GraphicsStore
    /// The first-run assistant, while one is open or set aside. The gallery
    /// draws the popover of a finished setup and passes none.
    var setup: SetupWindow?
    var presentation = PopoverPresentation()
    @State private var confirmingQuit = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Space.sm) {
            PopoverHeader("Sevoflurane")
            if supervisor.isQuitting {
                QuittingNotice()
            } else if let setup, setup.isUnfinished {
                SetupUnfinishedNotice(setup: setup)
                FooterBar(host: host, supervisor: supervisor, isSettingUp: true) { confirmingQuit = true }
            } else {
                SupervisorNotice(host: host, supervisor: supervisor)
                HostPressureNotice(pressure: supervisor.hostPressure)
                GamesColumn(
                    host: host, supervisor: supervisor, graphics: graphics,
                    quickLaunch: quickLaunch, presentation: presentation,
                )
                NotificationPermissionCard(notifications: notifications)
                SharingQuestionCard()
                BottleIncompleteChip()
                    .font(.system(size: 10))
                    .padding(.horizontal, Theme.Space.sm)
                SteamRow(host: host, supervisor: supervisor)
                FooterBar(host: host, supervisor: supervisor, graphics: graphics) { confirmingQuit = true }
            }
        }
        // Tighter than Propofol's outer `lg`: this popover's rows carry their
        // own inset, and at `lg` the two stack into a wide empty gutter.
        .padding(Theme.Space.md)
        .frame(width: Theme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Grows out of the ✕ over the footer rather than replacing the popover, which would jump
        // its size.
        .overlay(alignment: .bottom) {
            if confirmingQuit, !supervisor.isQuitting {
                QuitConfirmation { confirmingQuit = false }
                    .padding(Theme.Space.md)
                    .transition(.scale(scale: 0.18, anchor: .bottomTrailing).combined(with: .opacity))
            }
        }
        .animation(.spring(response: 0.34, dampingFraction: 0.82), value: confirmingQuit)
        .modifier(
            PopoverAnimations(
                host: host, supervisor: supervisor, notifications: notifications,
                quickLaunch: quickLaunch,
            ),
        )
        // What an open refreshes lands as the popover's first frame, not as
        // rows sliding and fading in: nothing animates while it settles.
        .transaction { transaction in
            if presentation.isSettling {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        // Reopening lands on the popover, never on a stale question.
        .onDisappear { confirmingQuit = false }
        .onAppear {
            host.refreshRecentGames()
            quickLaunch.refresh()
            graphics.refresh()
            SilentUpdates.shared.refresh()
            UpdateSummary.shared.checkOnce()
        }
    }

    /// "Friends", or what is waiting in it. The count is conversations, not
    /// messages — it is the number Steam itself posts to the client for its
    /// own tray badge, and a conversation is what a click opens.
    static func friendsLabel(unreadChats: Int) -> String {
        switch unreadChats {
        case 0: String(localized: "Friends")
        case 1: String(localized: "Friends · 1 new message")
        default: String(localized: "Friends · \(unreadChats) new messages")
        }
    }
}

// MARK: - Animation

/// The moments after the popover goes on screen. An open refreshes the
/// library, the programs and the renderer, and their answers arrive within
/// its first half second; animated, they read as the popover assembling
/// itself.
@MainActor
@Observable
final class PopoverPresentation {
    private(set) var isSettling = false
    private var settle: Task<Void, Never>?

    func opened() {
        isSettling = true
        settle?.cancel()
        settle = Task(name: "Popover settles") { [weak self] in
            try? await Task.sleep(for: Self.settleTime)
            guard !Task.isCancelled else { return }
            self?.isSettling = false
        }
    }

    private static let settleTime = Duration.milliseconds(500)
}

/// The one curve every region of the popover moves on, keyed to each value
/// whose change adds, removes or reorders something. The values are read
/// here, so a change re-runs this modifier and leaves ``MenuBarView``'s body
/// alone.
private struct PopoverAnimations: ViewModifier {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let notifications: SteamNotifications
    let quickLaunch: QuickLaunchStore

    func body(content: Content) -> some View {
        content
            .animation(.smooth(duration: 0.3), value: supervisor.health)
            .animation(.smooth(duration: 0.3), value: supervisor.hostPressure?.sentence)
            .animation(.smooth(duration: 0.3), value: host.recentGames)
            .animation(.smooth(duration: 0.3), value: host.libraryGames)
            .animation(.smooth(duration: 0.3), value: host.activeLaunch)
            .animation(.smooth(duration: 0.3), value: host.unreadChats)
            .animation(.smooth(duration: 0.3), value: notifications.hasUnaskedNotifications)
            .animation(.smooth(duration: 0.3), value: quickLaunch.programs)
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

// MARK: - Quitting

/// The whole popover while the app quits: the bottle takes several seconds to come down, and
/// until it has, the daemon reports a client nobody wants — which reads as auto-restart being
/// paused, not as a quit in progress.
private struct QuittingNotice: View {
    var body: some View {
        HStack(spacing: Theme.Space.md) {
            ProgressView().controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text("Quitting")
                    .font(.system(.body, design: .rounded).weight(.medium))
                Text("Closing Steam and anything running in it. Sevoflurane quits after Steam closes.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Theme.Space.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

// MARK: - Unfinished setup

/// Everything else the popover offers is Steam's, and Steam's windows are held
/// behind the assistant until its finish button — so while setup is unfinished
/// the way back into it is the whole popover.
private struct SetupUnfinishedNotice: View {
    let setup: SetupWindow

    var body: some View {
        NoticeCard(
            symbol: "wand.and.stars", tint: .accentColor,
            title: "Finish setting up",
            detail: "Continue setup where you left off. Steam opens from its last step.",
        ) { setup.show() }
            .accessibilityLabel("Continue setup")
    }
}

// MARK: - Health card

/// The supervisor's card: what is wrong with the client and the way out of
/// it, absent while the client is healthy.
private struct SupervisorNotice: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor

    var body: some View {
        if let card = model {
            NoticeCard(
                symbol: card.symbol, tint: card.tint, isSpinning: isRestarting,
                title: card.title, detail: card.detail,
            ) {
                if let action = card.action {
                    Button(action: action.run) { Text(action.label) }
                        .buttonStyle(.glassProminent)
                        .foregroundStyle(Theme.onAccent)
                }
                if let alternative = card.alternative {
                    Button(action: alternative.run) { Text(alternative.label) }
                        .buttonStyle(.glass)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    /// What the supervisor card shows for the current health state, or `nil`
    /// when the client is healthy and the card stays out of the way.
    private struct HealthCard {
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        /// Severity color for the symbol. The card's glass stays neutral in
        /// every state: a card that turns red carries the alarm twice, and the
        /// popover is where the user comes to *fix* it.
        let tint: Color?
        let action: (label: LocalizedStringResource, run: () -> Void)?
        /// A second, quieter button beside the first — the state where the
        /// user has somewhere to go *and* something to try again.
        var alternative: (label: LocalizedStringResource, run: () -> Void)?
    }

    /// Supervision runs in a background helper macOS asks the user to approve,
    /// so "it is not approved" is a state of its own with a way out, not a
    /// Steam fault to restart out of.
    private var daemonCard: HealthCard {
        HealthCard(
            symbol: "gearshape.badge.exclamationmark",
            title: "Sevoflurane needs its background helper",
            detail: status,
            tint: .red,
            action: ("Open Login Items", { DaemonService.openLoginItems() }),
            alternative: ("Retry", {
                Task(name: "Retry the daemon") { await supervisor.attach() }
            }),
        )
    }

    private var model: HealthCard? {
        if supervisor.daemonIsUnreachable { return daemonCard }
        return switch supervisor.health {
        case .healthy:
            nil
        case .starting:
            HealthCard(
                symbol: "hourglass",
                title: "Starting up",
                detail: status,
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
                detail: "\(phase.sentenceCased)",
                tint: nil,
                action: nil,
            )
        case .waitingForSignIn where host.signInIsSkipped:
            HealthCard(
                symbol: "person.crop.circle",
                title: "Steam is signed out",
                detail: "Run Windows programs from Quick Launch. Sign in to Steam to view your library.",
                tint: nil,
                action: ("Sign In to Steam", { host.showSteam() }),
            )
        case .waitingForSignIn:
            HealthCard(
                symbol: "person.crop.circle",
                title: "Waiting for sign-in",
                detail: "Sign in to Steam to see your library.",
                tint: nil,
                action: ("Show Login Window", { host.showSteam() }),
            )
        case .degraded:
            HealthCard(
                symbol: "exclamationmark.triangle.fill",
                title: "Steam is having trouble",
                detail: status,
                tint: .orange,
                action: nil,
            )
        case .restarting:
            HealthCard(
                symbol: "arrow.triangle.2.circlepath",
                title: "Restarting Steam",
                detail: status,
                tint: .accentColor,
                action: nil,
            )
        case .gaveUp:
            HealthCard(
                symbol: "exclamationmark.octagon.fill",
                title: "Steam needs attention",
                detail: status,
                tint: .red,
                action: ("Restart Now", { supervisor.restartNow() }),
                alternative: ("Recovery…", {
                    NSApp.sendAction(#selector(AppDelegate.showRecovery(_:)), to: nil, from: nil)
                }),
            )
        case .paused:
            HealthCard(
                symbol: "moon.zzz",
                title: "Auto-restart is off",
                detail: "Steam starts and stops only when you ask.",
                tint: nil,
                action: ("Turn On", { supervisor.setAutoRestart(true) }),
            )
        }
    }

    /// The supervisor's own phrase, written for a log line, as a sentence.
    private var status: LocalizedStringResource {
        "\(supervisor.statusText.sentenceCased)"
    }

    private var isRestarting: Bool {
        if case .restarting = supervisor.health { true } else { false }
    }
}

// MARK: - The Mac's load

/// What else weighs on this Mac, shown only while it is more than ordinary:
/// a game that starts slowly or stutters under someone else's work is this
/// card's to explain, before the person blames the game or this app.
private struct HostPressureNotice: View {
    let pressure: HostPressure?

    var body: some View {
        if let pressure, let sentence = pressure.sentence {
            NoticeCard(
                symbol: "thermometer.gauge.open", tint: .orange, level: pressure.level,
                title: "Your Mac is under heavy load",
                detail: "\(sentence) Games launch and run more slowly while this continues.",
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}

// MARK: - Games column

/// What to play: the recent games and the Windows programs, the column the
/// popover has always shown, at that column's own height. For a library
/// bigger than the recent five, scrolling it brings every installed game up
/// from below, under its letter; until then nothing hints at them, so the
/// popover stands exactly as it did.
private struct GamesColumn: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let quickLaunch: QuickLaunchStore
    let presentation: PopoverPresentation
    /// The height of the recent games and the programs, which the scroll
    /// view stands at.
    @State private var visibleHeight: CGFloat = 0
    @State private var position = ScrollPosition(edge: .top)
    /// Bumped by a pin change, which rewrites a game's config. Held here, so a
    /// game pinned in one list reads as pinned in the other too.
    @State private var pinEdits = 0

    /// Whether the index adds anything: a library the recent rows already
    /// show whole needs no second copy under letters.
    private var showsIndex: Bool {
        host.libraryGames.count > host.recentGames.count
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 0) {
                    RecentGames(
                        host: host, supervisor: supervisor, graphics: graphics,
                        pinEdits: pinEdits, onPinChanged: { pinEdits += 1 },
                    )
                    QuickLaunchPrograms(quickLaunch: quickLaunch)
                    AddProgramRow(quickLaunch: quickLaunch)
                }
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { visibleHeight = $0 }
                if showsIndex {
                    LibraryIndexList(
                        host: host, supervisor: supervisor, graphics: graphics,
                        pinEdits: pinEdits, onPinChanged: { pinEdits += 1 },
                    )
                }
            }
        }
        .scrollPosition($position)
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: visibleHeight)
        // Every open starts at the recent games, not wherever the last one
        // was left.
        .onChange(of: presentation.isSettling) { _, isSettling in
            if isSettling { position.scrollTo(edge: .top) }
        }
    }
}

/// A letter heading in the index, in the small hand the column's other
/// secondary lines use.
private struct ColumnHeading: View {
    let text: Text

    var body: some View {
        text
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Theme.Space.sm)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Row facts

/// What a game row reads from disk: its pin, its restart need and the
/// bundle it can be kept in the Dock as.
private nonisolated struct GameRowFacts: Equatable, Sendable {
    let pinned: Renderer?
    let restartFor: Renderer?
    let dockBundle: URL?
}

/// Reads the rows' facts from the game configs off the main actor rather
/// than on every body evaluation, and again whenever they can have changed.
private struct GameRowFactsReader: ViewModifier {
    let games: [Int]
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    /// Its choice is what a row's restart need is measured against.
    let graphics: GraphicsStore
    let pinEdits: Int
    @Binding var facts: [Int: GameRowFacts]

    /// What the facts depend on: the rows, and the moments the booted record,
    /// the bottle's renderer or a pin can change. The booted record and a pin
    /// live in plain storage that observation cannot see; the client rewrites
    /// the record when it boots and when a launch restages it, which is when
    /// `health` and `activeLaunch` move.
    private struct Key: Equatable {
        let games: [Int]
        let health: SupervisorHealth
        let launch: Int?
        let renderer: Renderer
        let pinEdits: Int
    }

    func body(content: Content) -> some View {
        content
            .task(id: Key(
                games: games,
                health: supervisor.health,
                launch: host.activeLaunch?.appID,
                renderer: graphics.selection.renderer,
                pinEdits: pinEdits,
            )) {
                facts = await Self.read(games)
            }
    }

    @concurrent
    private nonisolated static func read(_ games: [Int]) async -> [Int: GameRowFacts] {
        Dictionary(uniqueKeysWithValues: games.map { id in
            (id, GameRowFacts(
                pinned: GameConfig.game(id).renderer,
                restartFor: BottleGraphics.rendererNeedingRestart(forApp: id),
                dockBundle: GameLaunchers.dockableBundle(appID: id),
            ))
        })
    }
}

// MARK: - Recent games

/// The library's five most recently played games.
///
/// No heading: five pieces of box art under the app's own name need no
/// label to say they are games.
private struct RecentGames: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let pinEdits: Int
    let onPinChanged: () -> Void
    @State private var facts: [Int: GameRowFacts] = [:]

    var body: some View {
        content
            .modifier(GameRowFactsReader(
                games: host.recentGames.map(\.id), host: host, supervisor: supervisor,
                graphics: graphics, pinEdits: pinEdits, facts: $facts,
            ))
    }

    @ViewBuilder private var content: some View {
        if host.recentGames.isEmpty {
            // A popover with nothing between the header and the button reads
            // as a failure; a library with no installed games is not one.
            // Said only of a client that is up: while it starts, the list is
            // still loading and the health card says so.
            if supervisor.health == .healthy {
                Text("No games installed yet.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Theme.Space.sm)
            }
        } else {
            VStack(spacing: 1) {
                ForEach(host.recentGames) { game in
                    GameRow(
                        game: game,
                        launchDetail: host.activeLaunch
                            .flatMap { $0.appID == game.id ? $0.detail : nil },
                        pinned: facts[game.id]?.pinned,
                        restartFor: facts[game.id]?.restartFor,
                        dockBundle: facts[game.id]?.dockBundle,
                        isHeldInCloudSync: host.gamesHeldInCloudSync.contains(game.id),
                        supervisor: supervisor,
                        onPinChanged: onPinChanged,
                    )
                }
            }
        }
    }
}

// MARK: - Library index

/// Every installed game, under the letter Steam's library sorts it by, after
/// the recent games and the programs. The rows are the recent games' rows, so
/// a game plays, pins and opens its settings the same from either list.
private struct LibraryIndexList: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let graphics: GraphicsStore
    let pinEdits: Int
    let onPinChanged: () -> Void
    @State private var facts: [Int: GameRowFacts] = [:]

    var body: some View {
        // Lazy: a library of hundreds asks for art only for the rows scrolled to.
        LazyVStack(alignment: .leading, spacing: 1) {
            ForEach(LibraryIndex.sections(host.libraryGames)) { section in
                ColumnHeading(text: Text(verbatim: section.heading))
                ForEach(section.games) { game in
                    GameRow(
                        game: game,
                        launchDetail: host.activeLaunch
                            .flatMap { $0.appID == game.id ? $0.detail : nil },
                        pinned: facts[game.id]?.pinned,
                        restartFor: facts[game.id]?.restartFor,
                        dockBundle: facts[game.id]?.dockBundle,
                        isHeldInCloudSync: host.gamesHeldInCloudSync.contains(game.id),
                        supervisor: supervisor,
                        onPinChanged: onPinChanged,
                    )
                }
            }
        }
        .modifier(GameRowFactsReader(
            games: host.libraryGames.map(\.id), host: host, supervisor: supervisor,
            graphics: graphics, pinEdits: pinEdits, facts: $facts,
        ))
    }
}

/// One game: its capsule art, its name, and a press that launches it.
private struct GameRow: View {
    let game: SteamWebHost.RecentGame
    /// What the client says it is doing right now for this app
    /// (game-action events); `nil` outside a launch.
    let launchDetail: String?
    /// The renderer this game is pinned to, if any.
    let pinned: Renderer?
    /// The renderer this launch would have to restart the client for.
    let restartFor: Renderer?
    /// The game's own bundle, once a launch has built one.
    let dockBundle: URL?
    /// The client has kept this game at Synchronizing for longer than a sync takes.
    let isHeldInCloudSync: Bool
    let supervisor: ClientSupervisor
    let onPinChanged: () -> Void
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
            Task(name: "Clear the launch acknowledgment") {
                try? await Task.sleep(for: .seconds(8))
                withAnimation(.easeInOut(duration: 0.3)) { isLaunching = false }
            }
        } label: {
            HStack(spacing: Theme.Space.md) {
                capsuleArt
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: game.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if let status {
                        status.line
                            .font(.system(size: 10))
                            .foregroundStyle(status.isWarning ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                            .lineLimit(1)
                            .transition(.opacity)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
                // Flush with the trailing edge the footer's buttons and the
                // cards above keep: the badge is all a hovered row shows.
                trailing
            }
            // No horizontal inset: the art, the Open Steam button and the
            // footer chips all start at the popover's own padding, so the
            // column reads as one edge rather than the rows sitting in
            // from everything else.
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Theme.innerShape)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(verbatim: game.name))
        .accessibilityValue(status?.line ?? (isLaunching ? Text("Launching") : Text(verbatim: "")))
        .accessibilityHint("Plays the game")
        .accessibilityAction(named: "Game Settings") {
            GameSettingsItem.open(id: game.id, name: game.name)
        }
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .modifier(DockDrag(bundle: dockBundle))
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
            Divider()
            KeepInDockItem(bundle: dockBundle)
            GameSettingsItem(id: game.id, name: game.name)
        }
    }

    /// The line under the name: what the client is doing with the game, or
    /// what its next launch will do. VoiceOver reads it as the row's value.
    private var status: (line: Text, isWarning: Bool)? {
        if let launchDetail {
            // The client's own words for its launch phase.
            return (Text(verbatim: launchDetail), false)
        }
        if game.isInCloudSync {
            return isHeldInCloudSync
                ? (Text("Steam is stuck synchronizing. Restart Steam to play."), true)
                : (Text("Synchronizing with Steam Cloud"), false)
        }
        if let restartFor {
            // Pinned to a renderer the running client did not boot with: the
            // launch path restages it (or restarts, if the engine or sync must
            // change). Better said before the click than after.
            return (Text("\(restartFor.label) · set when it launches"), false)
        }
        return nil
    }

    /// The press is the app's claim to the activation right, and the game's
    /// window is what it will be spent on a minute later. The popover itself
    /// is a non-activating panel — it must stay one, or every click in it
    /// would pull focus off whatever the user was doing — so the press says
    /// so explicitly instead.
    private func launch() {
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Launch \(game.name)") { await supervisor.launch(game) }
    }

    /// Swap to this renderer and launch immediately (context menu).
    private func runWith(_ renderer: Renderer) {
        ActivationPolicy.claimRightForALaunch()
        Task(name: "Run \(game.name) on \(renderer.label)") {
            await supervisor.launch(game, renderer: renderer)
        }
    }

    private func setPin(_ renderer: Renderer?) {
        GameConfig.update(
            game: game.id, bottle: SteamBottle.name, prefix: SteamBottle.root, inBackground: true,
        ) {
            $0.renderer = renderer
            if $0.name == nil { $0.name = game.name }
        }
        onPinChanged()
    }

    /// What the pin menu reads and writes.
    private var pinBinding: Binding<Renderer?> {
        Binding(get: { pinned }, set: { setPin($0) })
    }

    private var capsuleArt: some View {
        AsyncImage(url: game.artURL) { image in
            image.resizable().scaledToFill()
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

// MARK: - Quick Launch

/// The Windows programs the user handed to Sevoflurane, in the games'
/// column: they launch the same way, so they read as more of the same list.
private struct QuickLaunchPrograms: View {
    let quickLaunch: QuickLaunchStore

    var body: some View {
        ForEach(quickLaunch.programs) { entry in
            ProgramRow(
                entry: entry,
                icon: quickLaunch.icon(for: entry),
                quickLaunch: quickLaunch,
            )
        }
    }
}

/// One adopted program: its own icon, its name, and a press that starts
/// it through the daemon.
private struct ProgramRow: View {
    let entry: AdoptedPrograms.Entry
    let icon: NSImage?
    let quickLaunch: QuickLaunchStore
    @State private var isHovered = false
    @State private var dockBundle: URL?

    var body: some View {
        Button {
            quickLaunch.launch(entry)
        } label: {
            HStack(spacing: Theme.Space.md) {
                artwork
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: entry.name)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    if !entry.program.exists {
                        Text("moved or deleted")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Theme.Space.sm)
            }
            .padding(.vertical, Theme.Space.xs)
            .contentShape(Theme.innerShape)
        }
        .buttonStyle(PressableStyle())
        .disabled(!entry.program.exists)
        .accessibilityLabel(Text(verbatim: entry.name))
        .accessibilityHint("Plays the game")
        .accessibilityAction(named: "Game Settings") {
            GameSettingsItem.open(id: entry.id, name: entry.name)
        }
        .background(
            Theme.innerShape.fill(Color.primary.opacity(isHovered ? 0.07 : 0)),
        )
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
        .modifier(DockDrag(bundle: dockBundle))
        .task(id: entry.id) { dockBundle = await Self.readDockBundle(entry.id) }
        .contextMenu {
            Menu("Run with…") {
                ForEach(Renderer.allCases.filter { $0 != .auto }, id: \.self) { renderer in
                    Button(renderer.label) { quickLaunch.launch(entry, renderer: renderer) }
                }
            }
            Divider()
            KeepInDockItem(bundle: dockBundle)
            Button("Show in Finder") { quickLaunch.showInFinder(entry) }
            Button("Remove") { quickLaunch.remove(entry) }
            Divider()
            GameSettingsItem(id: entry.id, name: entry.name)
        }
    }

    @concurrent
    private nonisolated static func readDockBundle(_ id: Int) async -> URL? {
        GameLaunchers.dockableBundle(appID: id)
    }

    private var artwork: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable()
            } else {
                Image(systemName: "app.dashed")
                    .resizable()
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(width: 27, height: 27)
        .padding(.vertical, 6)
    }
}

// MARK: - Dock

/// Keeps the game's own bundle in the Dock, where a click starts it through
/// the app and the running game lights the same tile. Offered once a launch
/// has built the bundle.
private struct KeepInDockItem: View {
    let bundle: URL?

    var body: some View {
        if let bundle {
            Button("Keep in Dock") { DockTiles.keep(bundle) }
        }
    }
}

/// A row with a bundle drags out as that bundle, for dropping on the Dock.
private struct DockDrag: ViewModifier {
    let bundle: URL?

    func body(content: Content) -> some View {
        if let bundle {
            content.onDrag { NSItemProvider(object: bundle as NSURL) }
        } else {
            content
        }
    }
}

/// The line that adds one, hung under the last row in a smaller hand: it
/// belongs to the list above it, and an empty Quick Launch is what it is for.
private struct AddProgramRow: View {
    let quickLaunch: QuickLaunchStore
    @State private var isHovered = false

    var body: some View {
        Button {
            quickLaunch.chooseProgram()
        } label: {
            HStack(spacing: Theme.Space.md) {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 27)
                Text("Add Windows Game…")
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: Theme.Space.sm)
            }
            .foregroundStyle(isHovered ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
            .padding(.vertical, 3)
            .contentShape(.rect)
            // The game row above ends in its own `xs` of padding and the
            // popover's `sm` stack spacing follows below, so this evens the
            // gap on both sides of the line.
            .padding(.top, Theme.Space.xs)
        }
        .buttonStyle(PressableStyle())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { isHovered = hovering }
        }
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
private struct NotificationPermissionCard: View {
    let notifications: SteamNotifications

    var body: some View {
        if notifications.hasUnaskedNotifications || notifications.authorization == .denied {
            let denied = notifications.authorization == .denied
            NoticeCard(
                symbol: "bell.badge",
                title: denied ? "Notifications are off" : "Steam has a message",
                detail: denied
                    ? "Allow Sevoflurane notifications in System Settings to see Steam messages."
                    : "Allow Sevoflurane to show Steam messages in Notification Center.",
            ) {
                Button {
                    if denied {
                        notifications.openSystemSettings()
                    } else {
                        Task(name: "Ask for notification permission") {
                            await notifications.requestAuthorization()
                        }
                    }
                } label: {
                    denied ? Text("Open System Settings") : Text("Allow Notifications")
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Theme.onAccent)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}

/// The community database's question, for a player who set up before setup
/// asked it: shown once a run exists to share, gone for good once answered.
private struct SharingQuestionCard: View {
    @State private var isAsking = Preferences.sharesRunStats == nil && RunLog.hasRecords()

    var body: some View {
        if isAsking {
            NoticeCard(
                symbol: "chart.bar.xaxis",
                title: "Help other Mac players",
                detail: "Share each game's frame rate, resolution, and settings along with your Mac model. The data does not include your name. See Settings › General for exactly what is sent.",
            ) {
                HStack(spacing: Theme.Space.sm) {
                    Button("Share") { answer(true) }
                        .buttonStyle(.glassProminent)
                        .foregroundStyle(Theme.onAccent)
                    Button("Not Now") { answer(false) }
                        .buttonStyle(.glass)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private func answer(_ shares: Bool) {
        Preferences.sharesRunStats = shares
        EventLog.shared.log(.app, shares ? "run statistics: sharing" : "run statistics: not sharing")
        if shares {
            Task.detached(name: "Send queued shared runs") { await StatsUploader.shared.flush() }
        }
        withAnimation { isAsking = false }
    }
}

/// The context-menu way into a game's own page in Settings › Games, where
/// what the menu above it sets is one of many things.
private struct GameSettingsItem: View {
    let id: Int
    let name: String

    var body: some View {
        Button("Game Settings…") { Self.open(id: id, name: name) }
    }

    static func open(id: Int, name: String) {
        (NSApp.delegate as? AppDelegate)?.showGameSettings(id: id, name: name)
    }
}

// MARK: - Steam

/// Metrics the Steam row and the renderer switch share, so the two zones
/// under the games stand the same height.
private enum ZoneMetrics {
    static let controlHeight: CGFloat = 30
}

/// The client in one row of glass: the way to its window, the friends list,
/// and how it is. The last two rest as icons and say their word on hover, so
/// Open Steam, the row's one accent, keeps most of it.
private struct SteamRow: View {
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
    /// only how and nothing beside it says what about. The three that skip the name report
    /// something else: the Steam account, this app's own switch, and the restart it is in the
    /// middle of.
    private var status: (word: LocalizedStringResource, symbol: String) {
        switch supervisor.health {
        case .starting, .launching: ("Steam starting", "hourglass")
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
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .help("\(summary). Install them in Settings › Engine › Game dependencies.")
            }
        }
        .onAppear { summary = BottleReadiness.incompleteSummary() }
    }
}
