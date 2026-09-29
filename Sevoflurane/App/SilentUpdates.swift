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
/// One check loop serves both modes (`installsAutomatically`): with auto-update off the daily
/// check still runs and still answers ``availableVersion`` — the footer's version chip draws from
/// it — but nothing downloads or installs except through ``updateNow()``.
///
/// The update channel (``Preferences/updateChannel``) is the engine's: on Beta the check takes
/// GitHub prereleases as well as releases, on Release it takes releases alone.
@MainActor
@Observable
final class SilentUpdates {
    static let shared = SilentUpdates()

    static let owner = "kageroumado"
    static let repo = "sevoflurane"

    /// Once a day: finding an update sooner would not install it sooner anyway, because the gate
    /// holds every swap until the Mac is idle and no game is up.
    private static let checkInterval: TimeInterval = 60 * 60 * 24

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

    /// The one long-lived updater: daily check loop, `availableVersion`, and the quiet-moment
    /// install when the mode allows it. Created up front so its `Tiptoe` reconciles the recorded
    /// wait (and surfaces `justUpdatedTo`) even before `start()`.
    @ObservationIgnored private let github: TiptoeGitHub

    /// What `github` checks through, kept to set whether prereleases count: AppUpdater reads
    /// the flag at every check, so a channel change needs no new updater.
    @ObservationIgnored private let updater: AppUpdater

    /// Set by ``start(autoInstall:)``: a channel change checks again only once the loop runs.
    @ObservationIgnored private var isStarted = false

    private init() {
        updater = AppUpdater(owner: Self.owner, repo: Self.repo)
        updater.allowPrereleases = Self.takesPrereleases(Preferences.updateChannel)
        github = TiptoeGitHub(updater: updater, checkInterval: Self.checkInterval)
            .gate("a game is running") { await Self.noGameRunning() }
            .installsAutomatically(false)
        github.onChecksFailing = { error in
            let now = Date.now
            if let last = Preferences.updateFailureLoggedAt,
               now.timeIntervalSince(last) < Self.checkInterval { return }
            Preferences.updateFailureLoggedAt = now
            EventLog.enqueue(
                .update,
                "update checks are failing (said once a day): \(error.localizedDescription)",
            )
        }
        justUpdatedVersion = github.tiptoe.justUpdatedTo
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
            isStarted = true
        #endif
    }

    /// Whether a check on `channel` counts GitHub prereleases: Beta does, Release takes the
    /// releases alone.
    nonisolated static func takesPrereleases(_ channel: UpdateChannel) -> Bool {
        channel == .beta
    }

    /// Brings the check in line with the update channel, which Settings and `sevo engine
    /// channel` both write. A change checks again at once, so a Mac moved to Beta hears about
    /// the newest beta now rather than at tomorrow's check.
    func followUpdateChannel() {
        let wanted = Self.takesPrereleases(Preferences.updateChannel)
        guard updater.allowPrereleases != wanted else { return }
        updater.allowPrereleases = wanted
        guard isStarted else { return }
        Task(name: "Check for updates on the new channel") { [weak self] in
            await self?.github.checkNow()
            self?.refresh()
        }
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
        followUpdateChannel()
        pendingVersion = github.tiptoe.pending?.version
        availableVersion = github.availableVersion
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

    /// Every release and beta: `/releases/latest` leaves prereleases out, and while only betas
    /// are out it has nothing to show.
    var releasesPageURL: URL {
        URL(string: "https://github.com/\(Self.owner)/\(Self.repo)/releases")!
    }

    // MARK: - The gate

    /// What the app knows of a play session beyond the screen: whether a run is being recorded
    /// and whether a launch is in flight. Set by the app delegate, which owns both.
    @ObservationIgnored var sessionState: () -> (recording: Bool, launching: Bool) = { (false, false) }

    /// A Steam session is in play while a run is open, a launch is on its way, or a game's window
    /// is on screen — a game still loading has no window, and one on another Space or minimized
    /// may not show one. Any of them vetoes the swap.
    nonisolated static func mayInstall(recording: Bool, activeLaunch: Bool, gameWindow: Bool) -> Bool {
        !recording && !activeLaunch && !gameWindow
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
            )
        }
    }
}
