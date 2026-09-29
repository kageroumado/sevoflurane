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
    /// thread: its services stay initialized and its page keeps answering while
    /// that thread waits forever. A stuck client with no game running is
    /// restarted; with a game running it is reported, since a restart takes
    /// Steam away from the game.
    func clientMainThreadIsStuck() async -> Bool {
        guard Date.now.timeIntervalSince(lastNativeProbe) >= MainThreadProbe.every else {
            return nativeSilences >= MainThreadProbe.silencesToAct
        }
        lastNativeProbe = .now
        guard let answered = await PageProbe.nativeAnswers() else { return false }
        if answered {
            nativeSilences = 0
            return false
        }
        nativeSilences += 1
        log.log(.client, "steam.exe left a main-thread question unanswered (\(nativeSilences) in a row)")
        guard nativeSilences >= MainThreadProbe.silencesToAct else { return false }
        if await sweptLostWakes() { return false }
        if await Self.isGameRunning() {
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

    /// Asks msync+ for a lost-wake sweep before a stuck client is restarted or reported:
    /// a game that exited while it set an object steam.exe waits on leaves that thread
    /// asleep, and the sweep wakes it where a restart would take the client away. True
    /// when it woke something, and the next probe asks the client again.
    private func sweptLostWakes() async -> Bool {
        guard case let .swept(report) = await MsyncSweep.run(), report.lostWakes > 0 else { return false }
        for line in report.lines { log.log(.client, line) }
        transition(logging: .supervisor, "msync+ woke \(report.lostWakes) thread(s) left asleep; asking steam.exe again")
        nativeSilences = 0
        lastNativeProbe = .distantPast
        return true
    }
}
