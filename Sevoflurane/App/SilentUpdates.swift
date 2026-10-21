import AppKit
import AppUpdater
import Foundation
import Observation
import Tiptoe
import TiptoeGitHub

/// The app's updater: downloads from GitHub Releases, verifies, and swaps the bundle in place —
/// silently when the user allows it, on an explicit Update Now otherwise.
///
/// The heavy lifting is [Tiptoe](https://github.com/artginzburg/Tiptoe) over mxcl/AppUpdater:
/// AppUpdater checks the release, downloads the DMG, and verifies the Team ID against the running
/// app; Tiptoe decides *when* the swap may run, waiting for the Mac to go quiet. The swap restarts
/// the app, and here that is not merely awkward — a clean quit asks the daemon to tear the Steam
/// client down, so a swap during a play session would close the game's Steam out from under it. The
/// gate below vetoes exactly that. It is a veto, not a preference: Tiptoe's own patience relaxes
/// over days, this never does.
///
/// One check loop serves both modes (`installsAutomatically`): with auto-update off the
/// check still runs and still answers ``availableVersion`` — the footer's version chip draws from
/// it — but nothing downloads or installs except through ``updateNow()``.
///
/// The loop ticks every ``checkInterval``; between ticks, opening the popover or waking the Mac
/// repeats the check once it is ``staleAfter`` old, and the menus make one on demand. Each is a
/// single GitHub metadata request, which GitHub itself caches for a minute.
///
/// The check takes GitHub releases alone: every version of the app ships as one.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "sevoflurane"

    /// Every four hours: the version chip and the app menu say an update is out as soon as a
    /// check finds it, and a Mac that stays on for days hears about a fix the same day.
    private static let checkInterval: TimeInterval = 4 * 60 * 60

    /// A check older than this is repeated when the popover opens or the Mac wakes: the loop's
    /// tick may have landed while the Mac slept, or at a launch before the network was up.
    private static let staleAfter: TimeInterval = 60 * 60

    /// The network comes back a beat after the Mac does; asking at the wake notification itself
    /// fails and leaves the next try to the loop.
    private static let wakeGrace: Duration = .seconds(20)

    /// How often a failing check is written to the event log.
    private static let failureLogInterval: TimeInterval = 24 * 60 * 60

    /// When a downloaded update may replace the app. Steam's window is open for most of the
    /// time the app runs and holds nothing a relaunch loses, so only unsaved work (a sheet or
    /// a modal) blocks the swap; the game gate keeps it out of every play session. Five
    /// minutes without input at first, one minute after a day of waiting, and after a day the
    /// app asks (``askToRestart(for:)``).
    private static let quietPolicy = QuietPolicy(
        rungs: [
            .init(after: 0, idleSeconds: 5 * 60, windows: .onlyUnsavedBlocks),
            .init(after: 24 * 60 * 60, idleSeconds: 60, windows: .onlyUnsavedBlocks),
        ],
        escalateAfter: 24 * 60 * 60,
        pollInterval: 60,
        gateTimeout: 5,
    )

    /// Progress of a user-initiated Update Now, for the version chip. A successful install
    /// replaces the process, so the only terminal state this side of the swap is `.failed`.
    enum ManualPhase: Equatable {
        case idle
        case working
        case failed(String)
    }

    private(set) var manualPhase: ManualPhase = .idle

    /// The newest published version when it is newer than the running app, from the check loop —
    /// in both modes, downloaded or not. Refreshed by ``refresh()``; Tiptoe is not observable.
    private(set) var availableVersion: String?

    /// The version the automatic path has downloaded and is holding for a quiet moment. A stronger
    /// claim than ``availableVersion`` (downloaded and verified, not merely published).
    private(set) var pendingVersion: String?

    /// The version a silent (or manual) install brought us to, until the user has seen the notice.
    /// Read from Tiptoe's store at launch; cleared by ``acknowledgeUpdate()``.
    private(set) var justUpdatedVersion: String?

    /// The one long-lived updater: check loop, `availableVersion`, and the quiet-moment
    /// install when the mode allows it. Created up front so its `Tiptoe` reconciles the recorded
    /// wait and the post-update notice against the running bundle (a notice that outlived its
    /// version is dropped, `1.5` and `1.5.0` read as one version) even before `start()`.
    @ObservationIgnored private let github: TiptoeGitHub
    @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?

    /// When this object last asked GitHub itself. The loop's own ticks are not visible here, so
    /// this is a floor on freshness: a stale check may repeat a tick made minutes ago, at the
    /// cost of one cached metadata request.
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

    /// Holds the day-old prompt until nothing is being played: shown during a game, it would
    /// open behind it, and while it waits it counts as a modal that blocks the quiet install.
    private func askWhenNoGameRuns(version: String) async {
        while await !(Self.noGameRunning()) {
            try? await Task.sleep(for: Self.promptRetryInterval)
        }
        EventLog.enqueue(.update, "update \(version) has waited a day for a quiet moment; asking")
        ModalAlerts.present { SilentUpdates.shared.askToRestart(for: version) }
    }

    /// The update has been held for a day: the Mac is never idle long enough, or never idle
    /// without a game up. Asked once per held version; Later leaves it to the quiet moment.
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

    /// The menus' update item: asks GitHub, then offers to install what it found or says the
    /// app is current. Always asks, even with a version already known: the version the dialog
    /// names must be the newest, and a download held for days may be a release behind.
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

    /// Called once at launch with the user's setting. The loop always runs; the setting only
    /// decides whether a found update is downloaded and installed at a quiet moment or merely
    /// reported.
    func start(autoInstall: Bool) {
        // Never in DEBUG: a development build must not poll GitHub, and must never be swapped
        // out from under Xcode.
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

    /// Reacts to the version chip's Auto switch. Turning auto off keeps the check loop (and
    /// ``availableVersion``) running but downloads and installs nothing; a DMG already downloaded
    /// stays downloaded and installs only via ``updateNow()``.
    func setAutoInstall(_ enabled: Bool) {
        #if !DEBUG
            github.installsAutomatically(enabled)
        #endif
    }

    /// Copies Tiptoe's state into the observable properties. Called when the popover appears and
    /// after update actions — Tiptoe has no change callback.
    func refresh() {
        pendingVersion = github.tiptoe.pending?.version
        availableVersion = github.availableVersion
    }

    /// The check the popover's appearance and the Mac's waking make, when the last one is old
    /// enough to be worth repeating. Quiet: nothing in the UI shows its progress.
    func checkIfStale() {
        // A development build does not poll GitHub on its own.
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

    /// Download (if needed), verify, and install the newest release right away — the user asked,
    /// so no quiet moment is waited out and no gate is consulted. On success the app relaunches
    /// and this never returns to its caller in a meaningful way; still running a few seconds
    /// later means the attempt failed and `manualPhase` says so.
    func updateNow() async {
        guard manualPhase != .working else { return }
        #if DEBUG
            manualPhase = .failed("A development build cannot update itself.")
        #else
            manualPhase = .working

            // `github.updateNow()` asks GitHub itself and replaces a download that fell behind,
            // but answers a press during a running check with whatever is already held — with
            // auto-install off, nothing. So a check this object started finishes first.
            await checkInFlight?.value

            guard await github.updateNow() else {
                manualPhase = .failed(
                    "Could not download the update. Check your connection, or open the releases page.",
                )
                return
            }
            // A successful swap terminates this process on its own schedule, possibly a beat
            // after the install call returns — wait it out before declaring failure.
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

    /// What the app knows beyond the screen: whether a run is being recorded, whether a launch
    /// is in flight, and whether setup is installing something. Set by the app delegate, which
    /// owns all three.
    @ObservationIgnored var sessionState: () -> (recording: Bool, launching: Bool, settingUp: Bool) = {
        (false, false, false)
    }

    /// A Steam session is in play while a run is open, a launch is on its way, or a game's window
    /// is on screen — a game still loading has no window, and one on another Space or minimized
    /// may not show one. Setup at work holds the swap too: a quit tears down a half-built
    /// bottle. Any of them vetoes the swap.
    nonisolated static func mayInstall(
        recording: Bool, activeLaunch: Bool, gameWindow: Bool, settingUp: Bool = false,
    ) -> Bool {
        !recording && !activeLaunch && !gameWindow && !settingUp
    }

    /// `GameLaunchWatch` already knows how to tell a game's window from the client's own
    /// plumbing, so the window half of the veto is that same sighting.
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
