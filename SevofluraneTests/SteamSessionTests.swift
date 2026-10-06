import Foundation
import Testing
@testable import Sevoflurane

/// A Steam session lost to another sign-in of the account: what the
/// connection log says, and when the bottle's client takes the session back.
struct SteamSessionTests {
    /// Ely's bottle on 2026-10-05, as Steam wrote it when Steam for Mac signed
    /// in with the same account.
    private static let replaced = """
    [2026-10-05 22:49:40] [Logging On, 4, 39] [U:1:845470373] RecvMsgClientLogOnResponse() : [U:1:845470373] 'OK'
    [2026-10-05 22:49:40] [Logged On, 4, 39] [U:1:845470373] RecvMsgClientLogOnResponse() : processing complete
    [2026-10-05 22:51:02] [Logged On, 4, 39] [U:1:845470373] RecvMsgClientLoggedOff('Session Replaced')
    [2026-10-05 22:51:02] [Logged On, 4, 39] [U:1:845470373] AsyncDisconnect( bDontWaitOnTCPShutdown: false )
    [2026-10-05 22:51:02] [Logged Off, 4, 0] [U:1:845470373] ConnectionDisconnected('Disconnected By Remote Host') : 'Session Replaced' (155.133.248.42:27018, WebSocket)
    [2026-10-05 22:51:02] [Logged Off, 4, 0] [U:1:845470373] ConnectionDisconnected() not auto reconnecting due to Session Replaced
    [2026-10-05 22:51:02] [Logged Off, 0, 0] [U:1:845470373] Sending SteamServersDisconnected_t because we were logged on
    """

    private static func events(_ text: String) -> [SteamConnectionLog.Event] {
        text.split(separator: "\n").compactMap(SteamConnectionLog.event(in:))
    }

    private static func date(_ stamp: String) -> Date {
        (try? Date(stamp, strategy: SteamConnectionLog.stampFormat)) ?? .distantPast
    }

    private static let loss = SteamSessionLoss(
        reason: .sessionReplaced, account: "U:1:845470373", date: date("2026-10-05 22:51:02"),
    )

    // MARK: - The log

    @Test
    func `a replaced session stands with its account and time`() {
        #expect(SteamConnectionLog.fold(Self.events(Self.replaced)) == Self.loss)
    }

    @Test
    func `a sign-in after the loss clears it`() {
        let log = Self.replaced + """
        
        [2026-10-05 23:10:13] [Logging On, 4, 19] [U:1:845470373] RecvMsgClientLogOnResponse() : [U:1:845470373] 'OK'
        """
        #expect(SteamConnectionLog.fold(Self.events(log)) == nil)
    }

    @Test
    func `a new client run clears it`() {
        let log = Self.replaced + """
        
        [2026-10-05 23:12:00] [Logged Off, 0, 0] [U:1:845470373] Log session ended
        """
        #expect(SteamConnectionLog.fold(Self.events(log)) == nil)
        #expect(SteamConnectionLog.event(in: "[2026-10-06 03:05:49] Client version: 1788652215") == .runBoundary)
    }

    @Test
    func `a rejected sign-in leaves the loss standing`() {
        let rejected = "[2026-10-05 23:10:13] [Logging On, 4, 19] [U:1:845470373] "
            + "RecvMsgClientLogOnResponse() : [U:1:845470373] 'Logged In Elsewhere'"
        #expect(SteamConnectionLog.fold(Self.events(rejected), from: Self.loss) == Self.loss)
    }

    @Test
    func `logged in elsewhere is a loss too`() {
        let line = "[2026-10-05 22:51:02] [Logged On, 4, 7] [U:1:845470373] RecvMsgClientLoggedOff('Logged In Elsewhere')"
        #expect(SteamConnectionLog.fold(Self.events(line))?.reason == .loggedInElsewhere)
    }

    @Test
    func `other sign-outs are not losses`() {
        let log = """
        [2026-10-05 22:51:02] [Logged On, 4, 7] [U:1:382744611] RecvMsgClientLoggedOff('Service Unavailable')
        [2026-10-05 22:51:02] [Logged Off, 0, 0] [U:1:382744611] ConnectionDisconnected() not auto reconnecting due to user initiated logoff
        [2026-10-05 22:51:02] [Logged Off, 4, 0] [U:1:382744611] ConnectionDisconnected('OK') : 'OK' (155.133.248.43:27018, WebSocket)
        """
        #expect(Self.events(log).isEmpty)
    }

    @Test
    func `the follower reads only what was appended`() throws {
        let file = FileManager.default.temporaryDirectory
            .appending(path: "connection_log-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data((Self.replaced + "\n").utf8).write(to: file)
        var follower = SteamConnectionLog.Follower(file: file)
        var moved = follower.read()
        #expect(moved)
        #expect(follower.loss == Self.loss)
        moved = follower.read()
        #expect(!moved)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        // Half a line is left for the next read.
        try handle.write(contentsOf: Data(
            "[2026-10-05 23:10:13] [Logging On, 4, 19] [U:1:845470373] RecvMsgClientLogOnResponse() : ".utf8,
        ))
        moved = follower.read()
        #expect(!moved)
        try handle.write(contentsOf: Data("[U:1:845470373] 'OK'\n".utf8))
        try handle.close()
        moved = follower.read()
        #expect(moved)
        #expect(follower.loss == nil)
    }

    // MARK: - Who holds the session

    @Test
    func `steam for mac signing in that second holds the session`() {
        let signIn = SteamConnectionLog.latestSignIn(
            of: "U:1:845470373",
            in: ["[2026-10-05 22:51:02] [Logging On, 4, 2] [U:1:845470373] RecvMsgClientLogOnResponse() : [U:1:845470373] 'OK'"],
        )
        #expect(SessionReconnect.holder(of: Self.loss, steamForMacSignIn: signIn, handedOffAt: nil) == .steamForMac)
    }

    @Test
    func `a steam for mac sign-in hours earlier holds nothing`() {
        let signIn = Self.date("2026-10-05 18:00:00")
        #expect(SessionReconnect.holder(of: Self.loss, steamForMacSignIn: signIn, handedOffAt: nil) == .elsewhere)
    }

    @Test
    func `a loss minutes after a handoff is steam for mac`() {
        let handoff = Self.loss.date.addingTimeInterval(-240)
        #expect(SessionReconnect.holder(of: Self.loss, steamForMacSignIn: nil, handedOffAt: handoff) == .steamForMac)
        let yesterday = Self.loss.date.addingTimeInterval(-86400)
        #expect(SessionReconnect.holder(of: Self.loss, steamForMacSignIn: nil, handedOffAt: yesterday) == .elsewhere)
    }

    // MARK: - When to reconnect

    @Test
    func `steam for mac still running means wait`() {
        #expect(SessionReconnect.action(loss: Self.loss, holder: .steamForMac, steamForMacIsRunning: true)
            == .waitForSteamForMac)
    }

    @Test
    func `steam for mac quitting means reconnect`() {
        #expect(SessionReconnect.action(loss: Self.loss, holder: .steamForMac, steamForMacIsRunning: false)
            == .reconnect)
    }

    @Test
    func `another computer is the person's to take back`() {
        #expect(SessionReconnect.action(loss: Self.loss, holder: .elsewhere, steamForMacIsRunning: false) == .none)
        #expect(SessionReconnect.action(loss: Self.loss, holder: .elsewhere, steamForMacIsRunning: true) == .none)
    }

    @Test
    func `a signed-in client needs nothing`() {
        #expect(SessionReconnect.action(loss: nil, holder: nil, steamForMacIsRunning: false) == .none)
    }

    @Test
    func `the loss crosses the link`() throws {
        let snapshot = SupervisorSnapshot(.healthy, isBusyRestarting: false, version: "1", signedInElsewhere: Self.loss)
        let decoded = try JSONDecoder().decode(SupervisorSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.signedInElsewhere == Self.loss)
        #expect(decoded.supervisorHealth == .healthy)
    }
}
