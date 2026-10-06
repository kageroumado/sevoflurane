import AppKit
import Observation

/// When the bottle's Steam takes its session back after another client of
/// the same account signed it out.
///
/// Steam never reconnects after "Session Replaced", and reconnecting while
/// the other client still runs signs that one out in turn: the two would take
/// the account from each other for as long as both run. So a session Steam
/// for Mac took on this Mac comes back once Steam for Mac quits, and a session
/// taken anywhere else is the person's to take back.
nonisolated enum SessionReconnect {
    /// Which client holds the session the bottle lost.
    enum Holder: Equatable, Sendable {
        /// Valve's Steam for Mac on this Mac.
        case steamForMac
        /// Another computer, or a client this Mac cannot see.
        case elsewhere
    }

    enum Action: Equatable, Sendable {
        /// Signed in, or signed out by a client only the person can stop.
        case none
        /// Steam for Mac holds the session and is still running.
        case waitForSteamForMac
        case reconnect
    }

    /// How long after a handoff to Steam for Mac a loss is put down to it:
    /// Steam for Mac may update itself before it signs in.
    static let handoffWindow: TimeInterval = 600

    /// Steam for Mac holds the session when its own log shows the account
    /// signing in at the moment of the loss, or when the loss followed a game
    /// handed to it.
    static func holder(
        of loss: SteamSessionLoss, steamForMacSignIn: Date?, handedOffAt: Date?,
    ) -> Holder {
        if let signIn = steamForMacSignIn, SteamConnectionLog.signIn(at: signIn, caused: loss) {
            return .steamForMac
        }
        if let handoff = handedOffAt {
            let sinceHandoff = loss.date.timeIntervalSince(handoff)
            if sinceHandoff >= -SteamConnectionLog.causeWindow, sinceHandoff <= handoffWindow { return .steamForMac }
        }
        return .elsewhere
    }

    static func action(loss: SteamSessionLoss?, holder: Holder?, steamForMacIsRunning: Bool) -> Action {
        guard loss != nil, holder == .steamForMac else { return .none }
        return steamForMacIsRunning ? .waitForSteamForMac : .reconnect
    }
}

/// The app's half of a lost Steam session: the daemon reads the client's
/// connection log and reports the loss; this says so, offers Reconnect, and
/// reconnects by itself when the client that took the session was Steam for
/// Mac and it quits.
@MainActor
@Observable
final class SteamSessionWatch {
    /// The session the bottle's client lost, while it stays lost.
    private(set) var loss: SteamSessionLoss?
    /// Who took it.
    private(set) var holder: SessionReconnect.Holder?

    @ObservationIgnored private let bridge: SteamBridge
    @ObservationIgnored weak var notifications: SteamNotifications?
    /// When a game was last handed to Steam for Mac.
    @ObservationIgnored private var handedOffAt: Date?
    /// The loss this watch already reconnected for, so a reconnect that did
    /// not take is never retried on its own.
    @ObservationIgnored private var reconnectedFor: SteamSessionLoss?
    @ObservationIgnored private var quitObserver: (any NSObjectProtocol)?

    init(bridge: SteamBridge) {
        self.bridge = bridge
    }

    /// Whether Valve's Steam for Mac is running on this Mac.
    static var steamForMacIsRunning: Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: NativeSteam.bundleIdentifier)
            .contains { !$0.isTerminated }
    }

    /// Takes the daemon's report of the session.
    func update(_ reported: SteamSessionLoss?) {
        guard reported != loss else { return }
        loss = reported
        guard let reported else {
            holder = nil
            stopWatchingSteamForMac()
            notifications?.withdrawSignedInElsewhere()
            return
        }
        let signIn = SteamConnectionLog.latestSignIn(
            of: reported.account,
            in: LogTail.lastLines(of: NativeSteam.connectionLog, count: Self.steamForMacLogLines) ?? [],
        )
        let holder = SessionReconnect.holder(of: reported, steamForMacSignIn: signIn, handedOffAt: handedOffAt)
        self.holder = holder
        notifications?.postSignedInElsewhere(bySteamForMac: holder == .steamForMac)
        act()
    }

    /// How much of Steam for Mac's log is searched for its sign-in.
    private static let steamForMacLogLines = 2000

    /// A game is going to Steam for Mac, which signs the bottle's client out
    /// when it signs in: that loss is put down to Steam for Mac, and the
    /// session comes back when it quits.
    func noteHandoff() {
        handedOffAt = .now
    }

    /// Reconnects the bottle's client to Steam the way its own error dialog
    /// does: from Reconnect in the notification or the menu bar, and by
    /// itself once Steam for Mac quits.
    func reconnect(because reason: String) {
        guard let loss else { return }
        reconnectedFor = loss
        EventLog.shared.log(.client, "reconnecting Steam: \(reason)")
        Task(name: "Reconnect Steam") {
            let answer = await bridge.evaluateInClient("SteamClient.User.Reconnect(), \"sent\"")
            if answer == nil {
                EventLog.shared.log(.client, "Steam did not take the reconnect: the bridge has no connection to the client")
            }
        }
    }

    private func act() {
        switch SessionReconnect.action(loss: loss, holder: holder, steamForMacIsRunning: Self.steamForMacIsRunning) {
        case .none:
            stopWatchingSteamForMac()
        case .waitForSteamForMac:
            guard quitObserver == nil else { return }
            EventLog.shared.log(.client, "Steam for Mac holds the session — reconnecting once it quits")
            watchSteamForMac()
        case .reconnect:
            stopWatchingSteamForMac()
            guard reconnectedFor != loss else { return }
            reconnect(because: "Steam for Mac, which had signed it out, is not running")
        }
    }

    private func watchSteamForMac() {
        quitObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main,
        ) { [weak self] note in
            let quit = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            guard quit?.bundleIdentifier == NativeSteam.bundleIdentifier else { return }
            MainActor.assumeIsolated { self?.act() }
        }
    }

    private func stopWatchingSteamForMac() {
        guard let quitObserver else { return }
        NSWorkspace.shared.notificationCenter.removeObserver(quitObserver)
        self.quitObserver = nil
    }
}
