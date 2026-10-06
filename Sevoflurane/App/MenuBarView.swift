import AppKit
import Digoxin
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
    /// What the bottle is missing, read off the main actor on each open.
    @State private var bottleSummary: String?

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
                if let session = supervisor.session { SessionNotice(session: session) }
                HostPressureNotice(supervisor: supervisor)
                GamesColumn(
                    host: host, supervisor: supervisor, graphics: graphics,
                    quickLaunch: quickLaunch, presentation: presentation,
                )
                NotificationPermissionCard(notifications: notifications)
                SharingQuestionCard()
                UsageQuestionCard()
                BottleIncompleteChip(summary: bottleSummary)
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
        // The test opens files inside the prefix, which is not something a
        // view body may do. Held here because the chip is absent while the
        // bottle is complete, and a modifier on an absent view never runs.
        .task(id: presentation.isSettling) {
            bottleSummary = await BottleIncompleteChip.read()
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
///
/// Reads the pressure itself: it moves with every sample the daemon sends,
/// and read by ``MenuBarView`` it would re-run the whole popover each time.
private struct HostPressureNotice: View {
    let supervisor: ClientSupervisor

    var body: some View {
        if let pressure = supervisor.hostPressure, let sentence = pressure.sentence {
            NoticeCard(
                symbol: "thermometer.gauge.open", tint: .orange, level: pressure.level,
                title: "Your Mac is under heavy load",
                detail: "\(sentence) Games launch and run more slowly while this continues.",
            )
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }
}

// MARK: - The Steam session

/// The bottle's Steam signed out because its account signed in on another
/// client. The client is healthy, so the supervisor card stays away; this is
/// what says why Steam reads "No connection", and the way back.
private struct SessionNotice: View {
    let session: SteamSessionWatch

    var body: some View {
        if session.loss != nil {
            NoticeCard(
                symbol: "person.crop.circle.badge.exclamationmark",
                tint: .orange,
                title: "Steam signed out here",
                detail: session.holder == .steamForMac
                    ? "Your account signed in to Steam for Mac. Steam reconnects here when Steam for Mac quits."
                    : "Your account signed in on another computer.",
            ) {
                Button("Reconnect") { session.reconnect(because: "Reconnect in the menu bar") }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(Theme.onAccent)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
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

/// Digoxin's question: whether this Mac is counted among Sevoflurane's
/// users. Asked once, after the community database's question has its
/// answer; Settings › General holds the choice from then on.
private struct UsageQuestionCard: View {
    @State private var isAsking = Preferences.usageCounting == nil
        && !(Preferences.sharesRunStats == nil && RunLog.hasRecords())

    var body: some View {
        if isAsking {
            NoticeCard(
                symbol: "person.2",
                title: "Count yourself in",
                detail: "One anonymous check-in a day counts how many people use Sevoflurane. It never includes which games or programs you run. Settings \u{203A} General lists what is sent, and adds crash reports if you want them.",
            ) {
                HStack(spacing: Theme.Space.sm) {
                    Button("Count Me In") { answer(.counting) }
                        .buttonStyle(.glassProminent)
                        .foregroundStyle(Theme.onAccent)
                    Button("Not Now") { answer(.off) }
                        .buttonStyle(.glass)
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
        }
    }

    private func answer(_ tier: ConsentTier) {
        UsageCounting.choose(tier)
        withAnimation { isAsking = false }
    }
}
