import Foundation

/// The bottle's Steam lost its session to another sign-in of the same
/// account. An account holds one client session at a time, and the replaced
/// client shows "No connection" until someone reconnects it.
nonisolated struct SteamSessionLoss: Codable, Equatable, Sendable {
    enum Reason: String, Codable, Sendable {
        /// `'Session Replaced'`: a client signed in with the same account.
        case sessionReplaced
        /// `'Logged In Elsewhere'`.
        case loggedInElsewhere

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
    /// Local time.
    var date: Date
}

/// Steam's `logs/connection_log.txt`: append-only, one event per line, each
/// client run opening with a `Client version:` line:
///
/// ```
/// [2026-10-05 22:51:02] [Logged On, 4, 39] [U:1:845470373] RecvMsgClientLoggedOff('Session Replaced')
/// [2026-10-05 22:51:02] [Logged Off, 4, 0] [U:1:845470373] ConnectionDisconnected() not auto reconnecting due to Session Replaced
/// [2026-10-05 23:10:13] [Logging On, 4, 19] [U:1:845470373] RecvMsgClientLogOnResponse() : [U:1:845470373] 'OK'
/// ```
///
/// Steam for Mac writes the same format, which is how a loss is matched to
/// the client that caused it.
nonisolated enum SteamConnectionLog {
    enum Event: Equatable, Sendable {
        case lost(SteamSessionLoss)
        /// A sign-in the servers accepted.
        case signedIn(account: String, date: Date)
        /// The client started or ended a run, which clears any loss.
        case runBoundary
    }

    private static let lossReasons: [(text: String, reason: SteamSessionLoss.Reason)] = [
        (SteamSessionLoss.Reason.sessionReplaced.logWords, .sessionReplaced),
        (SteamSessionLoss.Reason.loggedInElsewhere.logWords, .loggedInElsewhere),
        ("LoggedInElsewhere", .loggedInElsewhere),
    ]

    /// What a line says about the session, if anything.
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

    /// The latest loss after `events`, until a sign-in or a new run clears it.
    /// Steam logs a loss twice (logoff, then not reconnecting); the first is
    /// kept.
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

    /// How close a sign-in must be to the loss to have caused it. Both are
    /// logged within the same second; the margin covers rounding and the two
    /// clients' queues.
    static let causeWindow: TimeInterval = 60

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

    static let stampFormat = Date.ParseStrategy(
        format: "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)):\(minute: .twoDigits):\(second: .twoDigits)",
        timeZone: .current,
    )
}

nonisolated extension SteamConnectionLog {
    /// Follows one client's log, reading only what was appended since the
    /// last read.
    struct Follower {
        let file: URL
        private(set) var loss: SteamSessionLoss?
        private var offset: UInt64?
        /// The device and inode last read, which a replaced file changes.
        private var identity: (device: dev_t, inode: ino_t)?

        init(file: URL) {
            self.file = file
        }

        /// How far back the first read looks: a run's state is in its last
        /// few dozen lines, and the log runs to megabytes.
        static let firstReadWindow: UInt64 = 256 * 1024

        /// Reads what was appended and answers whether the standing loss
        /// changed. A file that shrank, or a new file in its place, is read
        /// from its start.
        mutating func read() -> Bool {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return false }
            defer { try? handle.close() }
            var status = stat()
            guard fstat(handle.fileDescriptor, &status) == 0 else { return false }
            let current = (device: status.st_dev, inode: status.st_ino)
            if let identity, identity != current { offset = 0 }
            identity = current
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
