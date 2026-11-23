import Foundation

/// The question only steam.exe's main thread answers, asked of a client that otherwise
/// probes healthy, and what follows when it goes unanswered.
extension BottleSupervisor {
    enum MainThreadProbe {
        /// How often a healthy client is asked a question its own main thread
        /// answers (``PageProbe/nativeAnswers()``).
        static let every: TimeInterval = 30
        /// How many of those questions in a row go unanswered before the
        /// client counts as stuck.
        static let silencesToAct = 2
    }

    /// Whether a client that probes healthy has stopped answering on its main
    /// thread. The stall is sampled beside the log first; then the client is
    /// restarted, or only reported while a game runs.
    func clientMainThreadIsStuck() async -> Bool {
        guard Date.now.timeIntervalSince(lastNativeProbe) >= MainThreadProbe.every else {
            return nativeSilences >= MainThreadProbe.silencesToAct
        }
        lastNativeProbe = .now
        guard let answer = await PageProbe.nativeAnswers() else {
            // The page probe's case, logged once per streak.
            if !nativeProbeUnanswered {
                nativeProbeUnanswered = true
                log.log(.client, "the page gave no answer to the main-thread probe — asked again at the next probe")
            }
            return false
        }
        nativeProbeUnanswered = false
        guard answer.stuck else {
            nativeSilences = 0
            stuckReported = false
            return false
        }
        if nativeSilences == 0 { nativeSilentSince = .now }
        nativeSilences += 1
        if stuckReported {
            // Swept, sampled and reported already: the restart waits for the game.
            if await Self.isGameRunning() { return true }
            stuckReported = false
            nativeSilences = 0
            await restartClient(reason: "steam.exe stopped answering on its main thread")
            return true
        }
        log.log(
            .client,
            "steam.exe left a main-thread question unanswered: \(answer.silent.joined(separator: ", ")) "
                + "(\(nativeSilences) in a row)",
        )
        guard nativeSilences >= MainThreadProbe.silencesToAct else { return false }
        if await sweptLostWakes() { return false }
        await keepStuckClientEvidence(.mainThread, since: nativeSilentSince ?? .now)
        if await Self.isGameRunning() {
            stuckReported = true
            fault = .degraded("Steam stopped answering — restart the client when the game is done")
            transition(
                logging: .supervisor,
                "steam.exe is stuck on its main thread with a game running — reporting, not restarting",
            )
            return true
        }
        nativeSilences = 0
        await restartClient(reason: "steam.exe stopped answering on its main thread")
        return true
    }

    /// Samples a client that stopped answering and keeps the Wine log's end
    /// and Steam's dumps beside the samples (``StuckClientSample``), then says
    /// in the log what was kept and any known fault the Wine log names.
    /// Returns once the samples are written, which bounds how long the
    /// restart that follows is held back; that restart ends the processes
    /// sampled.
    ///
    /// - Parameter began: When the first probe of the episode went unanswered.
    func keepStuckClientEvidence(_ probe: StuckClientSample.Probe, since began: Date) async {
        guard let kept = await StuckClientSample.capture(probe, began: began) else {
            log.log(.client, "found no steam.exe or web helper to sample")
            return
        }
        for line in StuckClientSample.lines(describing: kept) {
            log.log(.client, line)
        }
    }

    /// Asks msync+ to wake threads a dead game left asleep before a stuck
    /// client is restarted; true when it woke something.
    private func sweptLostWakes() async -> Bool {
        guard case let .swept(report) = await MsyncSweep.run(), report.lostWakes > 0 else { return false }
        for line in report.lines { log.log(.client, line) }
        transition(logging: .supervisor, "msync+ woke \(report.lostWakes) thread(s) left asleep; asking steam.exe again")
        nativeSilences = 0
        lastNativeProbe = .distantPast
        return true
    }
}
