import AppKit
import AppUpdater
import Foundation
import Observation
import Tiptoe
import TiptoeGitHub

/// The app's updater: downloads from GitHub Releases, verifies, and swaps the bundle in place —
/// silently when the user allows it, on an explicit Update Now otherwise.
///
/// [Tiptoe](https://github.com/artginzburg/Tiptoe) over mxcl/AppUpdater: AppUpdater checks the
/// release, downloads the DMG and verifies the Team ID; Tiptoe waits for the Mac to go quiet. A
/// swap quits the app, which tears the Steam client down, so the game gate below vetoes it during
/// play and never relaxes.
///
/// With auto-update off the check loop still answers ``availableVersion`` for the version chip,
/// but nothing installs except through ``updateNow()``. The loop ticks every ``checkInterval``;
/// opening the popover or waking the Mac repeats a check ``staleAfter`` old. Each check is one
/// GitHub metadata request, cached by GitHub for a minute.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "sevoflurane"

    /// Every four hours, so a Mac that stays on hears about a fix the same day.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// A check older than this is repeated when the popover opens or the Mac wakes.
    private static let staleAfter: TimeInterval = 60 * 60

    /// The network comes back a beat after the Mac; a check at the wake notification fails.
    private static let wakeGrace: Duration = .seconds(20)

    /// How often a failing check is written to the event log.
    private static let failureLogInterval: TimeInterval = 24 * 60 * 60

    /// When a downloaded update may replace the app: five idle minutes, one after a day, then
    /// the app asks (``askToRestart(for:)``). Only unsaved work (a sheet or modal) blocks it,
    /// since Steam's window loses nothing to a relaunch.
    private static let quietPolicy = QuietPolicy(
        rungs: [
            .init(after: 0, idleSeconds: 5 * 60, windows: .onlyUnsavedBlocks),
            .init(after: 24 * 60 * 60, idleSeconds: 60, windows: .onlyUnsavedBlocks),
        ],
        escalateAfter: 24 * 60 * 60,
        pollInterval: 60,
        gateTimeout: 5,
    )

    /// Progress of Update Now, for the version chip. Success replaces the process, so the only
    /// terminal state is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The newest published version when newer than the running app. Refreshed by
    /// ``refresh()``, since Tiptoe is not observable.
    private(set) var availableVersion: String?

    /// The version downloaded, verified and held for a quiet moment.
    private(set) var pendingVersion: String?

    /// The version an install brought us to, until ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// Created up front so its `Tiptoe` reconciles the recorded wait and the post-update notice
    /// against the running bundle even before `start()`.
    @ObservationIgnored private let github: TiptoeGitHub
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// When this object last asked GitHub; the loop's own ticks are invisible here.
    @ObservationIgnored private var lastCheckedAt: Date?

    /// The one metadata request in flight, shared by whoever asks while it runs.
    @ObservationIgnored private var checkInFlight: Task<Void, Never>?

    private init() {
        let updater = AppUpdater(owner: Self.owner, repo: Self.repo)
        updater.allowPrereleases = false
        github = TiptoeGitHub(
            updater: updater, checkInterval: Self.checkInterval,
            tiptoe: Tiptoe(policy: Self.quietPolicy),
        )
        .gate("a game is running") { await Self.noGameRunning() }
        .installsAutomatically(false)
        github.onChecksFailing = { error in
            let now = Date.now
            if let last = Preferences.updateFailureLoggedAt,
               now.timeIntervalSince(last) < Self.failureLogInterval { return }
            Preferences.updateFailureLoggedAt = now
            EventLog.enqueue(
                .update,
                "update checks are failing (said once a day): \(error.localizedDescription)",
            )
        }
        github.tiptoe.onWaitingTooLong = { pending in
            Task(name: "Ask to restart for the held update") {
                await SilentUpdates.shared.askWhenNoGameRuns(version: pending.version)
            }
        }
        github.tiptoe.onWillInstall = { pending in
            EventLog.enqueue(.update, "installing update \(pending.version)")
        }
        justUpdatedVersion = github.tiptoe.justUpdatedTo
    }

    /// How often a held prompt looks again for a moment with no game up.
    private static let promptRetryInterval: Duration = .seconds(60)

    /// Holds the day-old prompt until no game runs: during one it would open behind the game.
    private func askWhenNoGameRuns(version: String) async {
        while await !(Self.noGameRunning()) {
            try? await Task.sleep(for: Self.promptRetryInterval)
        }
        EventLog.enqueue(.update, "update \(version) has waited a day for a quiet moment; asking")
        ModalAlerts.present { SilentUpdates.shared.askToRestart(for: version) }
    }

    /// Asks once per held version after a day without a quiet moment; Later leaves it waiting.
    private func askToRestart(for version: String) {
        let display = AppVersion.display(version)
        let alert = NSAlert()
        alert.messageText = "Sevoflurane \(display) is ready"
        alert.informativeText = "Restarting installs it. Steam closes and opens again, "
            + "along with any game running in it."
        alert.addButton(withTitle: "Restart to Update")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task(name: "Install the held update") {
            await updateNow()
            if case let .failed(message) = manualPhase { Self.alert(message) }
        }
    }

    /// The menus' update item. Always asks GitHub first: a download held for days may be a
    /// release behind.
    func checkOrInstallFromMenu() {
        #if DEBUG
            ModalAlerts.present {
                let alert = NSAlert()
                alert.messageText = "A development build cannot update itself."
                alert.runModal()
            }
        #else
            Task(name: "Update from the app menu") {
                await check()
                if let version = availableVersion ?? pendingVersion {
                    let playing = await !(Self.noGameRunning())
                    ModalAlerts.present { SilentUpdates.shared.confirmInstall(version, whilePlaying: playing) }
                    return
                }
                ModalAlerts.present {
                    let alert = NSAlert()
                    alert.messageText = "Sevoflurane is up to date"
                    alert.informativeText = "Version \(AppVersion.displayed(from: Bundle.main.infoDictionary, fallback: "dev")) is the newest release."
                    alert.runModal()
                }
            }
        #endif
    }

    /// Asks before the menu's update replaces the app: it closes Steam and any game in it.
    private func confirmInstall(_ version: String, whilePlaying playing: Bool) {
        let alert = NSAlert()
        alert.messageText = "Install Sevoflurane \(AppVersion.display(version))?"
        alert.informativeText = playing
            ? "A game is running. Installing closes it, then Steam, and opens Sevoflurane again."
            : "Installing closes Steam and opens Sevoflurane again."
        alert.addButton(withTitle: "Install and Restart")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task(name: "Install the update from the app menu") {
            await updateNow()
            if case let .failed(message) = manualPhase { Self.alert(message) }
        }
    }

    private static func alert(_ message: String) {
        ModalAlerts.present {
            let alert = NSAlert()
            alert.messageText = "Sevoflurane could not update"
            alert.informativeText = message
            alert.runModal()
        }
    }

    /// The app menu's title for ``checkOrInstallFromMenu()``.
    var menuItemTitle: String {
        if let version = (availableVersion ?? pendingVersion).map(AppVersion.display) {
            return "Install Update \(version)…"
        }
        return "Check for Updates…"
    }

    // MARK: - The check loop

    /// Called once at launch; `autoInstall` decides whether a found update installs at a quiet
    /// moment or is only reported.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub or be swapped under Xcode.
        #if !DEBUG
            github.installsAutomatically(autoInstall).start()
            wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didWakeNotification, object: nil, queue: .main,
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.checkAfterWake()
                }
            }
        #endif
    }

    /// Reacts to the version chip's Auto switch. Off, a downloaded DMG installs only via
    /// ``updateNow()``.
    func setAutoInstall(_ enabled: Bool) {
        #if !DEBUG
            github.installsAutomatically(enabled)
        #endif
    }

    /// Copies Tiptoe's state into the observable properties; Tiptoe has no change callback.
    func refresh() {
        pendingVersion = github.tiptoe.pending?.version
        availableVersion = github.availableVersion
    }

    /// A quiet check when the last one is ``staleAfter`` old.
    func checkIfStale() {
        #if !DEBUG
            if let lastCheckedAt, Date.now.timeIntervalSince(lastCheckedAt) < Self.staleAfter { return }
            Task(name: "Check for updates (stale)") { await check() }
        #endif
    }

    private func checkAfterWake() {
        Task(name: "Check for updates after wake") { [weak self] in
            try? await Task.sleep(for: Self.wakeGrace)
            self?.checkIfStale()
        }
    }

    /// One metadata request; a second caller while it runs waits for the same answer.
    private func check() async {
        if let checkInFlight {
            await checkInFlight.value
            return
        }
        let task = Task(name: "Check for updates") { [github] in
            await github.checkNow()
        }
        checkInFlight = task
        await task.value
        checkInFlight = nil
        lastCheckedAt = .now
        refresh()
    }

    // MARK: - Update Now

    /// Download (if needed), verify, and install the newest release right away, with no quiet
    /// moment or gate. On success the app relaunches; still running a few seconds later means
    /// the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed("A development build cannot update itself.")
        #else
            manualPhase = .working

            // During a running check `github.updateNow()` answers with what is held (nothing,
            // with auto-install off), so that check finishes first.
            await checkInFlight?.value

            guard await github.updateNow() else {
                manualPhase = .failed(
                    "Could not download the update. Check your connection, or open the releases page.",
                )
                return
            }
            // A successful swap may terminate the process a beat after the call returns.
            try? await Task.sleep(for: .seconds(4))
            refresh()
            // The swap's quit can run past four seconds while the teardown brings Steam down.
            guard !AppDelegate.isQuitting else { return }
            manualPhase = .failed(
                "Could not install the update. Try again, or open the releases page.",
            )
        #endif
    }

    /// The user has seen the failure notice.
    func dismissFailure() {
        if case .failed = manualPhase { manualPhase = .idle }
    }

    /// The user has seen the post-update notice.
    func acknowledgeUpdate() {
        justUpdatedVersion = nil
        github.tiptoe.acknowledge()
    }

    /// Every release, the newest first.
    var releasesPageURL: URL {
        URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases")!
    }

    // MARK: - The gate

    /// Whether a run is recorded, a launch is in flight, or setup is installing; set by the app
    /// delegate.
    @ObservationIgnored var sessionState: () -> (recording: Bool, launching: Bool, settingUp: Bool) = {
        (false, false, false)
    }

    /// Any of these vetoes the swap. All three game signals are needed: a loading game has no
    /// window, and a minimized one may not show one. A quit during setup tears down a half-built
    /// bottle.
    nonisolated static func mayInstall(
        recording: Bool, activeLaunch: Bool, gameWindow: Bool, settingUp: Bool = false,
    ) -> Bool {
        !recording && !activeLaunch && !gameWindow && !settingUp
    }

    /// The window signal is `GameLaunchWatch`'s sighting of a game window.
    private static func noGameRunning() async -> Bool {
        await MainActor.run {
            let session = shared.sessionState()
            return mayInstall(
                recording: session.recording,
                activeLaunch: session.launching,
                gameWindow: GameLaunchWatch.firstGameWindow() != nil,
                settingUp: session.settingUp,
            )
        }
    }
}
