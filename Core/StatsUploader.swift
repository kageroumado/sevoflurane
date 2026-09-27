import Foundation

/// Sends closed runs, and the reports people write about them, to the
/// community database, when the user said yes.
///
/// Runs wait in ``StatsStore/queueURL`` and reports in
/// ``StatsStore/reportQueueURL`` until a batch goes through; an item the
/// server has not taken within ``queueLife`` is dropped, so a Mac that is
/// never online does not grow a file forever. Every request is signed by the
/// install's ``StatsIdentity``, and carries a sequence number the server
/// requires to grow, so a captured request cannot be replayed.
actor StatsUploader {
    static let shared = StatsUploader()

    static let baseURL = ProcessInfo.processInfo.environment["SEVO_STATS_URL"].flatMap(URL.init(string:))
        ?? URL(string: "https://kagerou.glass/api/sevoflurane/v1")!
    static let installHeader = "Sevo-Install"
    static let signatureHeader = "Sevo-Signature"
    static let batchSize = 50
    static let reportBatchSize = 10
    static let queueLife: TimeInterval = 7 * 24 * 3600
    /// Waits between failed sends: a minute, then longer, up to six hours.
    static let backoff: [Duration] = [.seconds(60), .seconds(300), .seconds(1800), .seconds(7200), .seconds(21600)]
    /// The wait after the server refused to register another install from
    /// this address today: its cap is per day, so a shorter retry gets the
    /// same answer.
    static let registrationCapWait: Duration = .seconds(24 * 3600)
    /// The server's word on a 429 that is its per-minute write limit rather
    /// than the daily registration cap; both come from `POST /v1/installs`.
    static let perMinuteLimit = "too many requests"

    enum Failure: Error, Equatable {
        case noSecureEnclave
        case unreachable(String)
        case refused(status: Int, reason: String?)
        /// `POST /v1/installs` answered 429: five new installs already
        /// registered from this address today.
        case registrationCapped(reason: String?)
    }

    /// One item of a batch the server refused, from its `202` body.
    struct Rejection: Equatable, Sendable {
        var index: Int
        var why: String
    }

    /// How a send failed, as far as what to do next is concerned.
    enum FailureClass: Equatable, Sendable {
        /// Nothing answers these paths: the service is not deployed (404,
        /// 410, 501). Asking again in this launch would get the same answer.
        case serviceAbsent
        case unreachable
        case serverError
        case refused
        case noSecureEnclave
        /// The address's daily registration cap: wait a day, then register again.
        case registrationCapped
    }

    nonisolated static func failureClass(of error: any Error) -> FailureClass {
        switch error as? Failure {
        case .noSecureEnclave: .noSecureEnclave
        case .unreachable: .unreachable
        case .registrationCapped: .registrationCapped
        case let .refused(status, _) where [404, 410, 501].contains(status): .serviceAbsent
        case let .refused(status, _) where status >= 500: .serverError
        case .refused, nil: .refused
        }
    }

    /// The refused items of a batch, from the server's `202 {accepted, rejected[]}`.
    nonisolated static func rejections(in reply: Data) -> [Rejection] {
        guard let object = try? JSONSerialization.jsonObject(with: reply) as? [String: Any],
              let rejected = object["rejected"] as? [[String: Any]]
        else { return [] }
        return rejected.compactMap { item in
            guard let index = item["i"] as? Int else { return nil }
            return Rejection(index: index, why: item["why"] as? String ?? "no reason given")
        }
    }

    /// The wait after `failures` sends in a row failed, the first at zero.
    nonisolated static func wait(afterFailures failures: Int) -> Duration {
        backoff[min(max(failures, 0), backoff.count - 1)]
    }

    private var session = URLSession(configuration: .ephemeral)
    private var retry: Task<Void, Never>?
    private var isFlushing = false
    /// The service answered that it is not there; nothing is sent again
    /// until the app next launches.
    private var serviceAbsent = false
    /// The last failure's class, so a run of the same failure is logged once.
    private var lastFailure: FailureClass?

    /// Where the uploader's lines go: the app points this at ``EventLog``;
    /// `sevo` reports outcomes itself. Set once at process start, same
    /// contract as ``ClientLifecycle/log``.
    nonisolated(unsafe) static var log: @Sendable (String) -> Void = { _ in }

    /// A run closed. Queued when sharing is on and the run says something
    /// about the game; the send follows at once.
    nonisolated static func submit(_ record: RunRecord) {
        guard Preferences.sharesRunStats == true,
              let run = SharedRun(record: record, appVersion: appVersion)
        else { return }
        Task.detached(name: "Queue a shared run") {
            await shared.enqueue(run)
            await shared.flush()
        }
    }

    nonisolated static var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    /// A person reported on a run. Queued when sharing is on; the send
    /// follows at once. The run's standing in the ledger is the caller's to
    /// write, so the caller's next read sees it.
    nonisolated static func submit(_ report: SharedReport, forRun runID: String) {
        guard Preferences.sharesRunStats == true else { return }
        Task.detached(name: "Queue a community report") {
            await shared.enqueue(report, forRun: runID)
            await shared.flush()
        }
    }

    func enqueue(_ run: SharedRun) {
        var queue = StatsStore.readQueue()
        queue.append(StatsStore.Queued(queued: .now, run: run))
        StatsStore.writeQueue(queue)
    }

    func enqueue(_ report: SharedReport, forRun runID: String) {
        var queue = StatsStore.readReportQueue()
        queue.append(StatsStore.QueuedReport(queued: .now, runID: runID, report: report))
        StatsStore.writeReportQueue(queue)
    }

    /// Sends what is queued, runs then reports, a batch at a time,
    /// registering first when the server does not know this install yet.
    func flush() async {
        guard !isFlushing, !serviceAbsent, Preferences.sharesRunStats == true else { return }
        // A backoff that outlived the last launch, or that a closing run
        // arrived during, is waited out.
        if let next = StatsStore.readState().nextTry, next > .now {
            if retry == nil { scheduleRetry(in: .seconds(next.timeIntervalSinceNow)) }
            return
        }
        isFlushing = true
        defer { isFlushing = false }
        let cutoff = Date.now.addingTimeInterval(-Self.queueLife)
        var runs = StatsStore.readQueue().filter { $0.queued > cutoff }
        StatsStore.writeQueue(runs)
        var reports = StatsStore.readReportQueue().filter { $0.queued > cutoff }
        StatsStore.writeReportQueue(reports)
        do {
            try await drain(&runs, batchSize: Self.batchSize, kind: "runs") { StatsStore.writeQueue($0) } send: { batch, identity in
                try await self.send(batch.map(\.run), as: identity)
            } tally: { state, accepted in
                state.sentRuns += accepted
            }
            try await drain(&reports, batchSize: Self.reportBatchSize, kind: "reports") { StatsStore.writeReportQueue($0) } send: { batch, identity in
                try await self.send(batch, as: identity)
            } tally: { state, accepted in
                state.sentReports = (state.sentReports ?? 0) + accepted
            }
            lastFailure = nil
        } catch {
            noteFailure(error)
        }
    }

    /// Sends a queue a batch at a time, writing what is left after each and
    /// counting what the server accepted. A batch the server calls too large
    /// (413) goes again in halves, down to one item, which is dropped: an
    /// item is capped at 4 KB by construction, so one the server still
    /// refuses is not going to shrink.
    private func drain<Item>(
        _ queue: inout [Item], batchSize: Int, kind: String,
        persist: ([Item]) -> Void,
        send: ([Item], StatsIdentity) async throws -> Int,
        tally: (inout StatsStore.State, Int) -> Void,
    ) async throws {
        var size = batchSize
        while !queue.isEmpty {
            let batch = Array(queue.prefix(size))
            let identity = try await registeredIdentity()
            var accepted = 0
            do {
                accepted = try await send(batch, identity)
            } catch Failure.refused(status: 413, reason: _) where batch.count > 1 {
                size = batch.count / 2
                Self.log("the server called a batch of \(batch.count) \(kind) too large (413); sending smaller batches")
                continue
            } catch Failure.refused(status: 413, reason: _) {
                Self.log("the server called one of the \(kind) too large (413); dropped")
            }
            queue.removeFirst(batch.count)
            persist(queue)
            var state = StatsStore.readState()
            tally(&state, accepted)
            state.lastSent = .now
            state.lastError = nil
            state.failures = nil
            state.nextTry = nil
            StatsStore.writeState(state)
        }
    }

    /// What ``deleteShared()`` came to, when the server did not refuse it.
    enum DeleteOutcome: Equatable, Sendable {
        /// The server deleted every run `install` sent.
        case deleted(install: String)
        /// The server never registered this Mac, so it holds nothing from it.
        case notRegistered
        /// The server registered `install`, but its key no longer opens on
        /// this Mac (a backup restored onto another one), so nothing can sign
        /// the request and the runs stay in the database.
        case keyUnavailable(install: String)
    }

    /// Asks the server to forget every run this install sent, then forgets
    /// the install here: the next run shared, if any, comes from a new key.
    /// A refused or unsent request throws and leaves the install in place.
    @discardableResult
    func deleteShared() async throws -> DeleteOutcome {
        let outcome: DeleteOutcome
        switch (StatsIdentity.load(), StatsStore.readState().registered) {
        case let (identity?, _?):
            let body = try envelope(["install": identity.installID])
            try await request("DELETE", "installs/\(identity.installID)", body: body, as: identity)
            outcome = .deleted(install: identity.installID)
        case let (nil, registered?):
            outcome = .keyUnavailable(install: registered)
        case (_, nil):
            outcome = .notRegistered
        }
        resetIdentity()
        return outcome
    }

    /// Drops the key, the registration and the queue.
    func resetIdentity() {
        for url in [
            StatsStore.identityURL, StatsStore.queueURL, StatsStore.reportQueueURL, StatsStore.reportedURL,
            StatsStore.stateURL,
        ] {
            try? FileManager.default.removeItem(at: url)
        }
        Self.log("identity reset")
    }

    // MARK: - Registration

    private func registeredIdentity() async throws -> StatsIdentity {
        guard StatsIdentity.isAvailable else { throw Failure.noSecureEnclave }
        let identity: StatsIdentity
        if let stored = StatsIdentity.load() {
            identity = stored
        } else {
            identity = try StatsIdentity.create()
            var state = StatsStore.readState()
            state.registered = nil
            StatsStore.writeState(state)
        }
        guard StatsStore.readState().registered != identity.installID else { return identity }
        try await register(identity)
        return identity
    }

    private struct Challenge: Decodable {
        var challenge: String
    }

    private struct Registered: Decodable {
        var install: String
        var trust: String
    }

    private func register(_ identity: StatsIdentity) async throws {
        let (challengeData, _) = try await exchange(URLRequest(url: Self.baseURL.appendingPathComponent("challenge")))
        guard let challenge = try? JSONDecoder().decode(Challenge.self, from: challengeData),
              let challengeBytes = Data(base64Encoded: challenge.challenge)
        else { throw Failure.refused(status: 200, reason: "no challenge") }
        let evidence = await identity.evidence(challenge: challengeBytes)
        Self.log("registering with \(evidence.tier) evidence")
        var fields: [String: Any] = [
            "public_key": identity.publicKeyDER.base64EncodedString(),
            "challenge": challenge.challenge,
            "app": Self.appVersion,
        ]
        if let keyID = evidence.appAttestKeyID, let attestation = evidence.attestation {
            fields["app_attest"] = ["key_id": keyID, "attestation": attestation.base64EncodedString()]
        }
        if let token = evidence.deviceToken {
            fields["device_check"] = token.base64EncodedString()
        }
        let body = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
        let answer: Data
        do {
            answer = try await request("POST", "installs", body: body, as: identity)
        } catch Failure.refused(status: 429, reason: let reason) where reason != Self.perMinuteLimit {
            throw Failure.registrationCapped(reason: reason)
        }
        guard let registered = try? JSONDecoder().decode(Registered.self, from: answer),
              registered.install == identity.installID
        else { throw Failure.refused(status: 201, reason: "registration answered another install") }
        var state = StatsStore.readState()
        state.registered = registered.install
        state.trust = registered.trust
        StatsStore.writeState(state)
        Self.log("registered as \(registered.install) (\(registered.trust))")
    }

    // MARK: - Requests

    /// Sends one batch of runs and answers how many the server accepted. A
    /// batch is answered 202 even when the server refused some of its runs;
    /// those are dropped with the batch, since resending an invalid run gets
    /// the same answer, but the reasons are the only trace of them.
    private func send(_ runs: [SharedRun], as identity: StatsIdentity) async throws -> Int {
        let encoded = try runs.map { try JSONSerialization.jsonObject(with: JSONEncoder.stats.encode($0)) }
        let body = try envelope(["install": identity.installID, "runs": encoded])
        let reply = try await request("POST", "runs", body: body, as: identity)
        let rejected = Self.rejections(in: reply)
        if !rejected.isEmpty {
            Self.log("the server refused \(rejected.count) of \(runs.count) runs: \(rejected.map(\.why).joined(separator: "; "))")
        }
        return runs.count - rejected.count
    }

    /// Sends one batch of reports, writes each one's standing to the ledger,
    /// and answers how many the server accepted. Refused reports are dropped
    /// with the batch, as runs are; each reason is logged and kept beside the
    /// run so its row can say so.
    private func send(_ reports: [StatsStore.QueuedReport], as identity: StatsIdentity) async throws -> Int {
        let encoded = try reports.map { try JSONSerialization.jsonObject(with: JSONEncoder.stats.encode($0.report)) }
        let body = try envelope(["install": identity.installID, "reports": encoded])
        let reply = try await request("POST", "reports", body: body, as: identity)
        let rejected = Self.rejections(in: reply)
        let refusals = Dictionary(rejected.map { ($0.index, $0.why) }, uniquingKeysWith: { first, _ in first })
        var ledger = StatsStore.readReported()
        for (index, queued) in reports.enumerated() {
            let why = refusals[index]
            if let why {
                Self.log("the server refused the report on run \(queued.runID): \(why)")
            }
            ledger.removeAll { $0.runID == queued.runID }
            ledger.append(StatsStore.Reported(
                runID: queued.runID, verdict: queued.report.verdict, queued: queued.queued,
                sent: why == nil ? .now : nil, refused: why,
            ))
        }
        StatsStore.writeReported(ledger)
        return reports.count - rejected.count
    }

    /// The signed envelope's common fields: the version, the next sequence
    /// number and the time, beside the request's own.
    private func envelope(_ fields: [String: Any]) throws -> Data {
        var state = StatsStore.readState()
        state.seq += 1
        StatsStore.writeState(state)
        var all = fields
        all["v"] = SharedRun.envelopeVersion
        all["seq"] = state.seq
        all["sent"] = ISO8601DateFormatter().string(from: .now)
        return try JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])
    }

    @discardableResult
    private func request(_ method: String, _ path: String, body: Data, as identity: StatsIdentity) async throws -> Data {
        var request = URLRequest(url: Self.baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(identity.installID, forHTTPHeaderField: Self.installHeader)
        try request.setValue(identity.sign(body).base64EncodedString(), forHTTPHeaderField: Self.signatureHeader)
        return try await exchange(request).0
    }

    private func exchange(_ request: URLRequest) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = 30
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Failure.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200 ..< 300).contains(status) else {
            let reason = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw Failure.refused(status: status, reason: reason)
        }
        return (data, status)
    }

    private func noteFailure(_ error: any Error) {
        let description = switch error as? Failure {
        case .noSecureEnclave: "this Mac has no Secure Enclave"
        case let .unreachable(reason): "unreachable: \(reason)"
        case let .refused(status, reason): "refused (\(status))\(reason.map { ": \($0)" } ?? "")"
        case let .registrationCapped(reason): "registration refused (429)\(reason.map { ": \($0)" } ?? "")"
        case nil: error.localizedDescription
        }
        var state = StatsStore.readState()
        state.lastError = description
        StatsStore.writeState(state)
        // A server that forgot this install (a deleted database, a revoked
        // key) answers 401: register again on the next try.
        if case let .refused(status, _) = error as? Failure, status == 401 {
            state.registered = nil
            StatsStore.writeState(state)
        }
        let failure = Self.failureClass(of: error)
        defer { lastFailure = failure }
        if failure == .serviceAbsent {
            serviceAbsent = true
            retry?.cancel()
            retry = nil
            state.failures = nil
            state.nextTry = nil
            StatsStore.writeState(state)
            Self.log("the statistics service is not available (\(description)); queued runs wait, "
                + "and the next launch asks again")
            return
        }
        if failure == .registrationCapped {
            state.nextTry = Date.now.addingTimeInterval(TimeInterval(Self.registrationCapWait.components.seconds))
            StatsStore.writeState(state)
            if failure != lastFailure {
                Self.log("this address registered five installs today; retrying tomorrow")
            }
            scheduleRetry(in: Self.registrationCapWait)
            return
        }
        let failures = state.failures ?? 0
        let wait = Self.wait(afterFailures: failures)
        state.failures = failures + 1
        state.nextTry = Date.now.addingTimeInterval(TimeInterval(wait.components.seconds))
        StatsStore.writeState(state)
        if failure != lastFailure {
            Self.log("send failed, \(description); next try in \(wait), and more failures like it are not logged")
        }
        scheduleRetry(in: wait)
    }

    private func scheduleRetry(in wait: Duration) {
        retry?.cancel()
        retry = Task(name: "Retry sending shared runs and reports") {
            try? await Task.sleep(for: wait)
            guard !Task.isCancelled else { return }
            self.retry = nil
            await self.flush()
        }
    }
}
