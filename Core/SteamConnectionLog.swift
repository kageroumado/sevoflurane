import Foundation

/// The bottle's Steam lost its session to another sign-in of the same
/// account.
///
/// An account holds one full client session at a time. A second client
/// signing in — Steam for Mac on this Mac, or Steam on another computer —
/// replaces the first, and the first never reconnects by itself: Steam's own
/// UI shows "No connection" until someone reconnects it.
nonisolated struct SteamSessionLoss: Codable, Equatable, Sendable {
    /// The reason Steam's servers gave, as Steam logs it.
    enum Reason: String, Codable, Sendable {
        /// `'Session Replaced'`: a client signed in with the same account.
        case sessionReplaced
        /// `'Logged In Elsewhere'`.
        case loggedInElsewhere

        /// The reason in Steam's own words, for the event log.
        var logWords: String {
            switch self {
            case .sessionReplaced: "Session Replaced"
            case .loggedInElsewhere: "Logged In Elsewhere"
            }
        }
    }

    var reason: Reason
    /// The account that was signed out, as Steam writes it (`U:1:845470373`).
    var account: String
    /// When Steam logged it, in this Mac's local time.
    var date: Date
}

/// Steam's `logs/connection_log.txt`, read for what it says about the session.
///
/// The file is append-only text, one event per line, each run of the client
/// opening with a `Client version:` line:
///
/// ```
/// [2026-10-05 22:51:02] [Logged On, 4, 39] [U:1:845470373] RecvMsgClientLoggedOff('Session Replaced')
/// [2026-10-05 22:51:02] [Logged Off, 4, 0] [U:1:845470373] ConnectionDisconnected() not auto reconnecting due to Session Replaced
/// [2026-10-05 23:10:13] [Logging On, 4, 19] [U:1:845470373] RecvMsgClientLogOnResponse() : [U:1:845470373] 'OK'
/// ```
///
/// Steam for Mac writes the same format to its own copy, which is how a loss
/// is matched to the client that caused it.
nonisolated enum SteamConnectionLog {
    /// One line's meaning for the session.
    enum Event: Equatable, Sendable {
        /// The servers signed this client out because the account signed in
        /// somewhere else.
        case lost(SteamSessionLoss)
        /// A sign-in the servers accepted.
        case signedIn(account: String, date: Date)
        /// The client started or ended a run: whatever the previous run lost
        /// is no longer this client's state.
        case runBoundary
    }

    /// The reasons that mean "signed in elsewhere", in the words Steam logs.
    private static let lossReasons: [(text: String, reason: SteamSessionLoss.Reason)] = [
        (SteamSessionLoss.Reason.sessionReplaced.logWords, .sessionReplaced),
        (SteamSessionLoss.Reason.loggedInElsewhere.logWords, .loggedInElsewhere),
        ("LoggedInElsewhere", .loggedInElsewhere),
    ]

    /// What a line says, or nil for the many lines that say nothing about the
    /// session.
    static func event(in line: Substring) -> Event? {
        if line.contains("] Client version:") || line.hasSuffix("Log session ended") {
            return .runBoundary
        }
        if line.contains("RecvMsgClientLogOnResponse() : ["), line.hasSuffix("'OK'"),
           let account = account(in: line), let date = date(of: line) {
            return .signedIn(account: account, date: date)
        }
        guard let reason = lossReason(in: line), let account = account(in: line),
              let date = date(of: line) else { return nil }
        return .lost(SteamSessionLoss(reason: reason, account: account, date: date))
    }

    /// The loss that stands after `events`, starting from `state`: the latest
    /// loss, until a sign-in or a new run clears it. Steam logs a loss twice
    /// (the logoff, then the decision not to reconnect), and the first one
    /// is kept.
    static func fold(_ events: some Sequence<Event>, from state: SteamSessionLoss? = nil) -> SteamSessionLoss? {
        events.reduce(state) { standing, event in
            switch event {
            case let .lost(loss): standing?.account == loss.account ? standing : loss
            case .signedIn, .runBoundary: nil
            }
        }
    }

    /// The latest sign-in the servers accepted for `account`.
    static func latestSignIn(of account: String, in lines: some Sequence<Substring>) -> Date? {
        lines.reduce(nil) { latest, line in
            guard case let .signedIn(signedIn, date) = event(in: line), signedIn == account else { return latest }
            return date
        }
    }

    /// How close a sign-in must be to the loss to be the one that caused it.
    /// Both are logged within the same second; the rest is clock rounding and
    /// the two clients' own queues.
    static let causeWindow: TimeInterval = 60

    /// Whether a sign-in at `signIn` is the one that replaced the session
    /// `loss` describes.
    static func signIn(at signIn: Date, caused loss: SteamSessionLoss) -> Bool {
        abs(signIn.timeIntervalSince(loss.date)) <= causeWindow
    }

    // MARK: - Fields

    private static func lossReason(in line: Substring) -> SteamSessionLoss.Reason? {
        let logoff = line.range(of: "RecvMsgClientLoggedOff('").map { line[$0.upperBound...] }
            ?? line.range(of: "not auto reconnecting due to ").map { line[$0.upperBound...] }
        guard let logoff else { return nil }
        return lossReasons.first { logoff.hasPrefix($0.text) }?.reason
    }

    /// The first `[U:1:n]` on the line: the client's own account.
    private static func account(in line: Substring) -> String? {
        guard let open = line.range(of: "[U:1:") else { return nil }
        let digits = line[open.upperBound...].prefix { $0.isNumber }
        guard !digits.isEmpty, digits != "0" else { return nil }
        return "U:1:\(digits)"
    }

    /// The line's `[yyyy-MM-dd HH:mm:ss]` stamp, in local time.
    private static func date(of line: Substring) -> Date? {
        guard line.first == "[", let close = line.firstIndex(of: "]") else { return nil }
        let stamp = line[line.index(after: line.startIndex) ..< close]
        return try? Date(String(stamp), strategy: stampFormat)
    }

    /// A line's stamp: local time, to the second.
    static let stampFormat = Date.ParseStrategy(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        timeZone: .current,
    )
}

nonisolated extension SteamConnectionLog {
    /// Follows one client's log from where it stands, reading only what was
    /// appended since the last read.
    struct Follower {
        let file: URL
        /// The loss that stands, as far as the log has been read.
        private(set) var loss: SteamSessionLoss?
        private var offset: UInt64?

        init(file: URL) {
            self.file = file
        }

        /// How far back the first read looks. A run's state is in its last
        /// few dozen lines; the log itself runs to megabytes.
        static let firstReadWindow: UInt64 = 256 * 1024

        /// Reads what was appended and answers whether the standing loss
        /// moved. A file that shrank was replaced, and is read from its start.
        mutating func read() -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            guard let size = try? handle.seekToEnd() else { return false }
            let isFirstRead = offset == nil
            var start = offset ?? (size > Self.firstReadWindow ? size - Self.firstReadWindow : 0)
            if start > size { start = 0 }
            guard start < size, (try? handle.seek(toOffset: start)) != nil,
                  let data = try? handle.readToEnd() else { return false }
            // Only whole lines: a line being written is read again next time.
            guard let lastNewline = data.lastIndex(of: UInt8(ascii: "\n")) else { return false }
            offset = start + UInt64(lastNewline - data.startIndex + 1)
            var lines = String(decoding: data[...lastNewline], as: UTF8.self)
                .split(whereSeparator: \.isNewline)[...]
            // The window's first line is cut wherever the window began.
            if isFirstRead, start > 0 { lines = lines.dropFirst() }
            let before = loss
            loss = SteamConnectionLog.fold(lines.compactMap(SteamConnectionLog.event(in:)), from: loss)
            return loss != before
        }
    }
}
