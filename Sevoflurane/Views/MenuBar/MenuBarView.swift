import AppKit
import Digoxin
import Propofol
import SwiftUI
import UserNotifications

/// The menu-bar popover, top to bottom: what to play, the Steam client, and
/// the app's own bar with the renderer. Built on Propofol, the popover style
/// the maintainer's menu-bar apps share; the supervisor card appears only
/// when something needs attention.
struct MenuBarView: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let notifications: SteamNotifications
    let quickLaunch: QuickLaunchStore
    let graphics: GraphicsStore
    /// The sharing and usage questions, asked once each.
    let questions: ConsentQuestions
    /// The first-run assistant, while one is open or set aside.
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
                PopoverColumn(
                    host: host, supervisor: supervisor, notifications: notifications, quickLaunch: quickLaunch,
                    graphics: graphics, questions: questions, presentation: presentation,
                    bottleSummary: bottleSummary,
                ) { confirmingQuit = true }
            }
        }
        // Tighter than Propofol's `lg`: the rows carry their own inset.
        .padding(Theme.Space.md)
        .frame(width: Theme.popoverWidth)
        .fixedSize(horizontal: false, vertical: true)
        // Grows out of the ✕ over the footer; replacing the popover would jump its size.
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
        // Nothing animates while an open settles, so refreshed rows land as the first frame.
        .transaction { transaction in
            if presentation.isSettling {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        // Disk reads, kept off the body. Held here because a modifier on the
        // chip, absent for a complete bottle, would never run.
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
            SilentUpdates.shared.checkIfStale()
            UpdateSummary.shared.checkOnce()
        }
    }

    /// "Friends", or what is waiting in it. The count is conversations, the
    /// number Steam posts for its own tray badge.
    static func friendsLabel(unreadChats: Int) -> String {
        switch unreadChats {
        case 0: String(localized: "Friends")
        case 1: String(localized: "Friends · 1 new message")
        default: String(localized: "Friends · \(unreadChats) new messages")
        }
    }
}

// MARK: - The column

/// The popover with setup finished: the cards that need a word, what to
/// play, the Steam client, and the app's own bar.
private struct PopoverColumn: View {
    let host: SteamWebHost
    let supervisor: ClientSupervisor
    let notifications: SteamNotifications
    let quickLaunch: QuickLaunchStore
    let graphics: GraphicsStore
    let questions: ConsentQuestions
    let presentation: PopoverPresentation
    let bottleSummary: String?
    let onQuit: () -> Void

    var body: some View {
        SupervisorNotice(host: host, supervisor: supervisor)
        if let session = supervisor.session { SessionNotice(session: session) }
        HostPressureNotice(supervisor: supervisor)
        GamesColumn(
            host: host, supervisor: supervisor, graphics: graphics,
            quickLaunch: quickLaunch, presentation: presentation,
        )
        NotificationPermissionCard(notifications: notifications)
        SharingQuestionCard(questions: questions)
        UsageQuestionCard(questions: questions)
        BottleIncompleteChip(summary: bottleSummary)
            .font(.system(size: 10))
            .padding(.horizontal, Theme.Space.sm)
        SteamRow(host: host, supervisor: supervisor)
        FooterBar(host: host, supervisor: supervisor, graphics: graphics, onQuit: onQuit)
    }
}

// MARK: - Animation

/// The half second after the popover opens, while its refreshes answer.
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

/// The popover's one animation curve, keyed to each value that adds, removes
/// or reorders rows. Read here so a change leaves ``MenuBarView``'s body alone.
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

/// The whole popover while the app quits: the bottle takes seconds to come down, and the
/// daemon's state meanwhile would read as auto-restart paused.
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

/// Steam's windows are held until setup finishes, so while it is unfinished
/// the popover offers only the way back into it.
private struct SetupUnfinishedNotice: View {
    let setup: SetupWindow

    var body: some View {
        if let store = setup.store, let failure = store.provisioner.failure {
            // A pass that stopped with the window closed says so here.
            NoticeCard(
                symbol: "exclamationmark.triangle.fill", tint: .orange,
                title: "Setup stopped",
                detail: "\([failure.stage?.failedSentence ?? "", failure.cause].filter { !$0.isEmpty }.joined(separator: " "))",
            ) {
                Button("Try Again") { store.tryAgain() }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(Theme.onAccent)
            }
        } else if let store = setup.store, let stage = store.provisioner.stage, store.provisioner.isWorking {
            NoticeCard(
                symbol: "arrow.down.circle", tint: .accentColor, level: store.provisioner.passFraction,
                title: "Setting up Steam",
                detail: "\(Self.working(stage, in: store.provisioner))",
                onTap: { setup.show() },
            ) { EmptyView() }
                .accessibilityLabel("Continue setup")
        } else if let store = setup.store, store.workIsDone {
            let isReady = store.screen == .done
            NoticeCard(
                symbol: "checkmark.circle.fill", tint: .green,
                title: "Steam is installed",
                detail: isReady ? "It opens when setup closes." : "Setup has a question left.",
            ) {
                Button(isReady ? "Open Steam" : "Continue Setup") {
                    if isReady { store.finish() } else { setup.show() }
                }
                .buttonStyle(.glassProminent)
                .foregroundStyle(Theme.onAccent)
            }
        } else {
            NoticeCard(
                symbol: "wand.and.stars", tint: .accentColor,
                title: "Setup is not finished",
                detail: "Steam opens from its last screen.",
            ) {
                Button("Continue Setup") { setup.show() }
                    .buttonStyle(.glassProminent)
                    .foregroundStyle(Theme.onAccent)
            }
        }
    }

    /// The stage under way with its fraction in digits, where one is known.
    private static func working(_ stage: SetupStage, in provisioner: Provisioner) -> String {
        guard let fraction = provisioner.stageFraction else { return stage.workingSentence }
        let percent = fraction.formatted(.percent.precision(.fractionLength(0)).rounded(rule: .towardZero))
        return "\(stage.workingSentence) \(percent)"
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

    /// What the supervisor card shows for the current health state.
    private struct HealthCard {
        let symbol: String
        let title: LocalizedStringResource
        let detail: LocalizedStringResource
        /// Severity color for the symbol; the card's glass stays neutral.
        let tint: Color?
        let action: (label: LocalizedStringResource, run: () -> Void)?
        /// A second, quieter button beside the first.
        var alternative: (label: LocalizedStringResource, run: () -> Void)?
    }

    /// An unapproved background helper, with Login Items as the way out.
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
            // Only the phase says which startup this is: the card serves both.
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

/// Heavy load from other work on this Mac, which explains a slow or
/// stuttering game. Reads the pressure itself: it changes with every daemon
/// sample, and read by ``MenuBarView`` it would re-run the whole popover.
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
/// client, with the way back. The supervisor card stays away: the client is healthy.
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

/// Where the app asks to post notifications: after Steam's first
/// notification is held, and only on a click.
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

/// The community database's question for a player whose setup did not ask
/// it, shown once a run exists and until answered.
private struct SharingQuestionCard: View {
    let questions: ConsentQuestions

    var body: some View {
        if questions.asksSharing {
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
        withAnimation { questions.answerSharing(shares) }
    }
}

/// Digoxin's question, whether this Mac is counted among users: asked once,
/// after the community question is answered.
private struct UsageQuestionCard: View {
    let questions: ConsentQuestions

    var body: some View {
        if questions.asksUsage {
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
        withAnimation { questions.answerUsage(tier) }
    }
}
